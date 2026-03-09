#!/usr/bin/env python3
"""Wrapper for wasm_test: handles exit code checking and dir isolation."""

import argparse
import atexit
import os
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-exit-code", type=int, default=0)
    parser.add_argument("--isolate-dir", action="append", default=[])
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    cmd = args.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print("error: no command specified", file=sys.stderr)
        return 1

    if args.isolate_dir:
        scratch = tempfile.mkdtemp()
        atexit.register(shutil.rmtree, scratch, ignore_errors=True)
        for dir_spec in args.isolate_dir:
            if "::" in dir_spec:
                host, guest = dir_spec.split("::", 1)
            else:
                host, guest = dir_spec, os.path.basename(dir_spec)
            shutil.copytree(host, os.path.join(scratch, guest), symlinks=True)
            cmd = [a.replace(host, os.path.join(scratch, guest)) for a in cmd]

    result = subprocess.run(cmd)

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
