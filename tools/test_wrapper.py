#!/usr/bin/env python3
"""Wrapper for wasm_test: handles exit code checking and dir isolation.

Isolation requires --guest-args-count to protect the module and guest argv.
"""

import argparse
import atexit
import os
import shutil
import subprocess
import sys
import tempfile


def _split_dir_spec(dir_spec: str) -> tuple[str, str]:
    if "::" in dir_spec:
        host, guest = dir_spec.split("::", 1)
    else:
        host = guest = dir_spec

    if not host or not guest:
        raise ValueError(f"invalid WASI directory mapping: {dir_spec!r}")

    return host, guest


def _runtime_args_end(cmd: list[str], guest_args_count: int) -> int:
    """Locate the immutable module-and-guest-arguments suffix."""
    if guest_args_count < 0:
        raise ValueError("--guest-args-count must be non-negative")

    runtime_end = len(cmd) - guest_args_count - 1

    if runtime_end < 1:
        raise ValueError(
            f"--guest-args-count {guest_args_count} is too large for a command "
            f"with {len(cmd)} arguments: a runtime and module must remain"
        )

    return runtime_end


def _rewrite_dir_args(
    cmd: list[str],
    replacements: dict[str, str],
    *,
    guest_args_count: int,
) -> list[str]:
    runtime_end = _runtime_args_end(cmd, guest_args_count)
    rewritten = list(cmd)
    index = 0

    while index < runtime_end:
        arg = cmd[index]

        if arg == "--dir" and index + 1 < runtime_end:
            value = cmd[index + 1]

            if value in replacements:
                rewritten[index + 1] = replacements[value]

            index += 2
            continue
        elif arg.startswith("--dir="):
            value = arg.removeprefix("--dir=")

            if value in replacements:
                rewritten[index] = f"--dir={replacements[value]}"

        index += 1

    return rewritten


def _isolate_dirs(
    cmd: list[str],
    dir_specs: list[str],
    scratch: str,
    *,
    guest_args_count: int,
) -> list[str]:
    _runtime_args_end(cmd, guest_args_count)
    replacements = {}

    for index, dir_spec in enumerate(dir_specs):
        host, guest = _split_dir_spec(dir_spec)
        isolated_host = os.path.join(scratch, f"preopen-{index}")
        shutil.copytree(host, isolated_host, symlinks=os.name != "nt")
        replacements[dir_spec] = f"{isolated_host}::{guest}"

    return _rewrite_dir_args(
        cmd,
        replacements,
        guest_args_count=guest_args_count,
    )


def main():
    """Run a wasm_test command and compare its exit code to expectations."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-exit-code", type=int, default=0)
    parser.add_argument("--isolate-dir", action="append", default=[])
    parser.add_argument(
        "--guest-args-count",
        type=int,
        help=(
            "Exact number of guest arguments after the module; "
            "required with --isolate-dir."
        ),
    )
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    cmd = args.cmd

    if cmd and cmd[0] == "--":
        cmd = cmd[1:]

    if not cmd:
        print("error: no command specified", file=sys.stderr)
        return 1

    try:
        if args.guest_args_count is not None:
            _runtime_args_end(cmd, args.guest_args_count)

        if args.isolate_dir:
            if args.guest_args_count is None:
                raise ValueError(
                    "--guest-args-count is required with --isolate-dir"
                )

            scratch = tempfile.mkdtemp()
            atexit.register(shutil.rmtree, scratch, ignore_errors=True)
            cmd = _isolate_dirs(
                cmd,
                args.isolate_dir,
                scratch,
                guest_args_count=args.guest_args_count,
            )
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    result = subprocess.run(cmd, check=False)

    if result.returncode == args.expected_exit_code:
        return 0

    if args.expected_exit_code != 0:
        print(
            f"expected exit code {args.expected_exit_code}, "
            f"got {result.returncode}",
            file=sys.stderr,
        )

    return 1


if __name__ == "__main__":
    sys.exit(main())
