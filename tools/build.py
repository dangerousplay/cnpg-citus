#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["rich>=13.9"]
# ///
"""Build, test and push the cnpg-citus image for one or both architectures.

Multi-arch here means a manifest list pointing at one image per architecture,
not a fat image. `podman manifest` builds it; the same layout is what the CI
workflow produces, so a local build and a released one are the same shape.

Cross-architecture builds go through QEMU and are slow — the pg_durable step
alone is a Rust compile. Prefer building each architecture on its own hardware
(which is what the workflow does, on native runners) and use --arch here to
build only the one you are on.

    ./tools/build.py                          # host architecture, no push
    ./tools/build.py --arch amd64,arm64       # both, QEMU for the foreign one
    ./tools/build.py --test                   # build, then run the smoke test
    ./tools/build.py --push --registry ghcr.io/you
    ./tools/build.py --pg 17 --citus 13.3.0 --no-durable

Nothing is pushed unless --push is given, and --push refuses to run if the
smoke test has not passed in the same invocation.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.rule import Rule
from rich.table import Table

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "cnpg-citus"
ARCHES = ("amd64", "arm64")

console = Console()


class BuildError(RuntimeError):
    pass


def rule(title: str) -> None:
    console.print()
    console.print(Rule(f"[bold]{title}", align="left", style="cyan"))


def ok(msg: str) -> None:
    console.print(f"  [green]✓[/] {msg}")


def warn(msg: str) -> None:
    console.print(f"  [yellow]![/] {msg}")


def bad(msg: str) -> None:
    console.print(f"  [red]✗[/] {msg}")


def hint(msg: str) -> None:
    console.print(f"    [dim]{msg}[/]")


def engine() -> str:
    for candidate in ("podman", "docker"):
        if shutil.which(candidate):
            return candidate
    raise BuildError("neither podman nor docker is installed")


def run(cmd: list[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, capture_output=capture, text=True)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip() if capture else ""
        raise BuildError(f"{' '.join(cmd[:3])} failed{': ' + detail if detail else ''}")
    return proc


def host_arch() -> str:
    m = platform.machine().lower()
    return "arm64" if m in ("arm64", "aarch64") else "amd64"


# --------------------------------------------------------------------------- #


def tag_for(registry: str | None, pg: str, citus: str, durable: bool, arch: str | None = None) -> str:
    base = f"{registry}/{IMAGE}" if registry else f"localhost/{IMAGE}"
    version = f"{pg}-citus{citus}"
    if durable:
        version += "-durable"
    return f"{base}:{version}" + (f"-{arch}" if arch else "")


def build_one(arch: str, args, tag: str) -> None:
    """One architecture, one image. --platform is passed even for the native
    arch so the manifest entry carries the right os/arch rather than inheriting
    whatever the host happens to be."""
    cmd = [
        engine(), "build",
        "--platform", f"linux/{arch}",
        "-t", tag,
        "--build-arg", f"PG_MAJOR={args.pg}",
        "--build-arg", f"CITUS_VERSION={args.citus}",
        "--build-arg", f"PG_DURABLE_VERSION={args.durable_version}",
        "--build-arg", f"WITH_DURABLE={'true' if args.durable else 'false'}",
        "-f", str(ROOT / "Containerfile"),
        str(ROOT),
    ]
    if args.no_cache:
        cmd.insert(2, "--no-cache")
    console.print(f"  [dim]{' '.join(cmd)}[/]")
    started = time.monotonic()
    run(cmd)
    ok(f"{arch} built in {time.monotonic() - started:.0f}s → {tag}")


def smoke(arch: str, tag: str, args) -> bool:
    """Start the image as a real Postgres and exercise every extension.

    A build that produced the right files is not a build that works: the .so
    can be present and fail to load, and Citus specifically will not create
    without shared_preload_libraries. Only starting a postmaster proves it."""
    script = ROOT / "tools" / "smoke.sh"
    if not script.exists():
        raise BuildError(f"{script} is missing")
    proc = subprocess.run(
        [engine(), "run", "--rm", "--platform", f"linux/{arch}",
         "--user", "26",
         "-e", f"PG_MAJOR={args.pg}",
         "-e", f"WITH_DURABLE={'true' if args.durable else 'false'}",
         "-v", f"{script}:/smoke.sh:ro",
         "--entrypoint", "/bin/bash", tag, "/smoke.sh"],
        capture_output=True, text=True, timeout=900,
    )
    for line in (proc.stdout or "").splitlines():
        console.print(f"    [dim]{line}[/]")
    if proc.returncode != 0:
        bad(f"{arch} smoke test failed")
        for line in (proc.stderr or "").splitlines()[-15:]:
            console.print(f"    [red]{line}[/]")
        return False
    ok(f"{arch} smoke test passed")
    return True


def push_manifest(args, per_arch: dict[str, str]) -> None:
    """A manifest list, so `docker pull` on either architecture resolves to the
    right image without the caller naming one."""
    listed = tag_for(args.registry, args.pg, args.citus, args.durable)
    run([engine(), "manifest", "rm", listed], check=False, capture=True)
    run([engine(), "manifest", "create", listed])
    for arch, tag in per_arch.items():
        remote = f"{args.registry}/{IMAGE}:{listed.split(':')[1]}-{arch}"
        run([engine(), "tag", tag, remote])
        run([engine(), "push", remote])
        ok(f"pushed {remote}")
        run([engine(), "manifest", "add", listed, f"docker://{remote}"])
    run([engine(), "manifest", "push", "--all", listed, f"docker://{listed}"])
    ok(f"pushed manifest list {listed}")
    hint(f"{len(per_arch)} architectures: {', '.join(per_arch)}")


# --------------------------------------------------------------------------- #


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", default=host_arch(),
                        help=f"comma-separated: {','.join(ARCHES)} (default: this host)")
    parser.add_argument("--pg", default="17", help="PostgreSQL major (default 17)")
    parser.add_argument("--citus", default="13.3.0", help="Citus version (default 13.3.0)")
    parser.add_argument("--durable-version", default="0.2.5", help="pg_durable version")
    parser.add_argument("--no-durable", dest="durable", action="store_false",
                        help="skip pg_durable — much faster, it is a Rust build")
    parser.add_argument("--test", action="store_true", help="run the smoke test after building")
    parser.add_argument("--push", action="store_true", help="push, implies --test")
    parser.add_argument("--registry", default=os.environ.get("REGISTRY"),
                        help="e.g. ghcr.io/you — required with --push")
    parser.add_argument("--no-cache", action="store_true")
    args = parser.parse_args()

    arches = [a.strip() for a in args.arch.split(",") if a.strip()]
    for a in arches:
        if a not in ARCHES:
            parser.error(f"unknown architecture {a!r}; expected one of {', '.join(ARCHES)}")
    if args.push:
        if not args.registry:
            parser.error("--push needs --registry (or REGISTRY in the environment)")
        args.test = True  # never push something that was not exercised

    console.print(Panel.fit(
        f"[bold]{IMAGE}[/]\n"
        f"[dim]postgres {args.pg} · citus {args.citus}"
        f"{' · pg_durable ' + args.durable_version if args.durable else ' · no pg_durable'}\n"
        f"architectures: {', '.join(arches)}[/]",
        border_style="cyan",
    ))

    foreign = [a for a in arches if a != host_arch()]
    if foreign:
        warn(f"{', '.join(foreign)} is not this host — the build runs under QEMU")
        hint("expect it to be several times slower; CI builds each arch natively")

    per_arch: dict[str, str] = {}
    for arch in arches:
        rule(f"build · {arch}")
        tag = tag_for(None, args.pg, args.citus, args.durable, arch)
        build_one(arch, args, tag)
        per_arch[arch] = tag

    if args.test:
        for arch, tag in per_arch.items():
            rule(f"smoke test · {arch}")
            if not smoke(arch, tag, args):
                bad("not pushing — a smoke test failed")
                return 1

    if args.push:
        rule("push")
        push_manifest(args, per_arch)

    rule("summary")
    table = Table(show_header=True, header_style="bold", box=None, padding=(0, 2))
    table.add_column("arch")
    table.add_column("tag")
    table.add_column("tested")
    for arch, tag in per_arch.items():
        table.add_row(arch, tag, "[green]yes[/]" if args.test else "[yellow]no[/]")
    console.print(table)
    if not args.push:
        console.print()
        hint("nothing was pushed — add --push --registry <host>/<namespace>")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildError as exc:
        bad(str(exc))
        sys.exit(1)
    except subprocess.TimeoutExpired:
        bad("timed out")
        sys.exit(1)
    except KeyboardInterrupt:
        console.print("\n[dim]interrupted[/]")
        sys.exit(130)
