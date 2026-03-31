"""Build helper for AssemblyScript compilation.

Usage:
    python3 asc_build.py --node NODE --asc ASC --src SRC --out OUT \
        [--node-modules DIR] [--wasi] [--copy-modules] [-- asc_flags...]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", required=True)
    parser.add_argument("--asc", required=True)
    parser.add_argument("--src", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--node-modules", required=True)
    parser.add_argument("--wasi", action="store_true")
    parser.add_argument("--copy-modules", action="store_true")
    parser.add_argument("extra_flags", nargs="*")
    args = parser.parse_args()

    orig = os.getcwd()
    build = tempfile.mkdtemp()

    try:
        if args.wasi:
            src_nm = os.path.join(orig, args.node_modules)
            dst_nm = os.path.join(build, "node_modules")

            if args.copy_modules:
                shutil.copytree(src_nm, dst_nm)
            else:
                os.symlink(src_nm, dst_nm)

            with open(os.path.join(build, "asconfig.json"), "w") as f:
                json.dump(
                    {
                        "extends": "./node_modules/@assemblyscript/wasi-shim/asconfig.json"
                    },
                    f,
                )

        shutil.copy2(os.path.join(orig, args.src), os.path.join(build, "src_input.ts"))

        os.chdir(build)

        cmd = [
            os.path.join(orig, args.node),
            os.path.join(orig, args.asc),
            "src_input.ts",
            "-o",
            os.path.join(orig, args.out),
            "--path",
            os.path.join(orig, args.node_modules),
        ] + args.extra_flags

        rc = subprocess.call(cmd)
        sys.exit(rc)
    finally:
        os.chdir(orig)
        shutil.rmtree(build, ignore_errors=True)


if __name__ == "__main__":
    main()
