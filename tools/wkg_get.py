#!/usr/bin/env python3
"""Run wkg get and optionally verify the downloaded package digest."""

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--sha256")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command

    if command and command[0] == "--":
        command = command[1:]

    if not command:
        print("error: no wkg command specified", file=sys.stderr)
        return 1

    result = subprocess.run(command, check=False)

    if result.returncode != 0:
        return result.returncode

    if args.sha256:
        digest = hashlib.sha256(Path(args.output).read_bytes()).hexdigest()

        if digest != args.sha256.lower():
            print(
                f"error: package SHA-256 mismatch: expected {args.sha256}, "
                f"got {digest}",
                file=sys.stderr,
            )
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
