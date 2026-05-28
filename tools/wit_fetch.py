#!/usr/bin/env python3
"""Prepare a WIT directory and run `wkg wit fetch` inside it."""

import argparse
import os
import shutil
import subprocess
import sys


def _abs_path(arg: str, cwd: str) -> str:
    if os.path.isabs(arg):
        return arg
    return os.path.join(cwd, arg)


def _abs_command_arg(arg: str, cwd: str) -> str:
    candidate = _abs_path(arg, cwd)
    return candidate if os.path.exists(candidate) else arg


def _copy_wit(src: str, out_dir: str) -> None:
    name = os.path.basename(os.path.normpath(src))
    if os.path.isdir(src):
        shutil.copytree(src, out_dir, dirs_exist_ok=True)
    else:
        shutil.copy2(src, os.path.join(out_dir, name))


def main() -> int:
    """Copy WIT inputs to an output directory and run wkg wit fetch."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--wit", action="append", default=[])
    parser.add_argument("--config")
    parser.add_argument("--cache")
    parser.add_argument("wkg_wit", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    if args.wkg_wit and args.wkg_wit[0] == "--":
        args.wkg_wit = args.wkg_wit[1:]
    if not args.wkg_wit:
        print("error: no wkg wit command specified", file=sys.stderr)
        return 1
    if not args.wit:
        print("error: no WIT inputs specified", file=sys.stderr)
        return 1

    cwd = os.getcwd()
    out_dir = _abs_path(args.out_dir, cwd)
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)

    for src in args.wit:
        _copy_wit(_abs_path(src, cwd), out_dir)

    cmd = [_abs_command_arg(part, cwd) for part in args.wkg_wit]
    cmd.extend(["fetch", "--wit-dir", out_dir])
    if args.config:
        cmd.extend(["--config", _abs_path(args.config, cwd)])
    if args.cache:
        cmd.extend(["--cache", _abs_path(args.cache, cwd)])

    return subprocess.call(cmd, cwd=cwd)


if __name__ == "__main__":
    sys.exit(main())
