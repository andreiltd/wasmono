#!/usr/bin/env python3
"""Detect version changes in a git diff and output tool=version pairs.

Parses the git diff between the current HEAD and a base ref to find
version bumps in demo.bzl and cxx/wasi/releases.bzl.

Usage:
    python3 .github/scripts/detect-version-changes.py <base_ref>

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
    result = subprocess.run(
        ["git", "diff", f"origin/{base_ref}..HEAD", "--", path],
        capture_output=True, text=True, check=True,
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
    """Detect new version entries in cxx/wasi/releases.bzl."""
    diff = git_diff(base_ref, "toolchains/cxx/wasi/releases.bzl")
    updates = []
    for line in diff.splitlines():
        m = re.match(r'^\+\s+"(\d[\d.]+)":\s*\{', line)
        if m:
            updates.append(("wasi-sdk", m.group(1)))
    return updates


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <base_ref>", file=sys.stderr)
        sys.exit(1)

    base_ref = sys.argv[1]
    updates = detect_demo_bzl_changes(base_ref) + detect_wasi_sdk_changes(base_ref)

    if not updates:
        print("No version updates detected", file=sys.stderr)
        sys.exit(1)

    for tool, version in updates:
        print(f"{tool}={version}")


if __name__ == "__main__":
    main()
