#!/usr/bin/env python3
# pylint: disable=invalid-name
"""Detect version changes in a git diff and output tool=version pairs.

Parses the git diff between the current HEAD and a base ref to find
version bumps in demo.bzl and toolchains/BUCK.

Usage:
    python3 .github/scripts/detect-version-changes.py <base_commit>

Output (stdout, one per line):
    wasm-tools=1.246.0
    wasmtime=43.0.0
"""

import re
import subprocess
import sys

# Map parameter names in demo.bzl to tool names for update-releases.py
TOOL_NAME_MAP = {
    "wasm_tools": "wasm-tools",
    "wit_bindgen": "wit-bindgen",
    "wac": "wac",
    "wkg": "wkg",
    "binaryen": "binaryen",
    "wasmtime": "wasmtime",
    "node": "node",
}


def git_diff(base_ref: str, path: str) -> str:
    """Return the git diff for a path against a base ref."""
    result = subprocess.run(
        ["git", "diff", f"{base_ref}..HEAD", "--", path],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def detect_demo_bzl_changes(base_ref: str) -> list[tuple[str, str]]:
    """Detect version parameter changes in demo.bzl."""
    diff = git_diff(base_ref, "toolchains/wasm/demo.bzl")
    updates = []
    for line in diff.splitlines():
        m = re.match(r'^\+\s+(\w+)_version\s*=\s*"([^"]+)"', line)
        if m:
            param_name, version = m.group(1), m.group(2)
            tool_name = TOOL_NAME_MAP.get(param_name)
            if tool_name:
                updates.append((tool_name, version))
    return updates


def detect_wasi_sdk_changes(base_ref: str) -> list[tuple[str, str]]:
    """Detect WASI SDK version changes in toolchains/BUCK."""
    diff = git_diff(base_ref, "toolchains/BUCK")
    updates = []
    for line in diff.splitlines():
        m = re.match(r'^\+\s+version\s*=\s*"([^"]+)"', line)
        if m:
            updates.append(("wasi-sdk", m.group(1)))
    return updates


def main():
    """Print detected tool version updates."""
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <base_commit>", file=sys.stderr)
        sys.exit(1)

    base_ref = sys.argv[1]
    updates = (
        detect_demo_bzl_changes(base_ref)
        + detect_wasi_sdk_changes(base_ref)
    )

    for tool, version in updates:
        print(f"{tool}={version}")


if __name__ == "__main__":
    main()
