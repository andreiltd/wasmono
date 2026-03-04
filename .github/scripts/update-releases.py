#!/usr/bin/env python3
"""Download release artifacts and update releases.bzl with new checksums.

Usage:
    python3 .github/scripts/update-releases.py <tool> <version>

Examples:
    python3 .github/scripts/update-releases.py wasm-tools 1.246.0
    python3 .github/scripts/update-releases.py wasmtime 43.0.0
    python3 .github/scripts/update-releases.py binaryen 126
    python3 .github/scripts/update-releases.py wasi-sdk 28.0
    python3 .github/scripts/update-releases.py node 22.0.0
"""

import hashlib
import json
import os
import re
import sys
import textwrap
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# Tool configurations: URL templates, platforms, and target files.
# Each platform entry maps our internal key to URL template variables.
TOOLS = {
    "wasm-tools": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "wasm_tools_releases",
        "platforms": {
            "aarch64-linux": "aarch64-linux",
            "aarch64-macos": "aarch64-macos",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
            "x86_64-windows": "x86_64-windows",
        },
        "url": "https://github.com/bytecodealliance/wasm-tools/releases/download/v{version}/wasm-tools-{version}-{platform}.{ext}",
        "ext": lambda p: "zip" if "windows" in p else "tar.gz",
    },
    "wit-bindgen": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "wit_bindgen_releases",
        "platforms": {
            "aarch64-linux": "aarch64-linux",
            "aarch64-macos": "aarch64-macos",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
            "x86_64-windows": "x86_64-windows",
        },
        "url": "https://github.com/bytecodealliance/wit-bindgen/releases/download/v{version}/wit-bindgen-{version}-{platform}.{ext}",
        "ext": lambda p: "zip" if "windows" in p else "tar.gz",
    },
    "wac": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "wac_releases",
        "platforms": {
            "aarch64-apple-darwin": "aarch64-apple-darwin",
            "aarch64-unknown-linux-musl": "aarch64-unknown-linux-musl",
            "x86_64-apple-darwin": "x86_64-apple-darwin",
            "x86_64-pc-windows-gnu": "x86_64-pc-windows-gnu",
            "x86_64-unknown-linux-musl": "x86_64-unknown-linux-musl",
        },
        "url": "https://github.com/bytecodealliance/wac/releases/download/v{version}/wac-cli-{platform}",
        "ext": lambda p: "",
    },
    "wkg": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "wkg_releases",
        "platforms": {
            "aarch64-apple-darwin": "aarch64-apple-darwin",
            "aarch64-unknown-linux-gnu": "aarch64-unknown-linux-gnu",
            "x86_64-apple-darwin": "x86_64-apple-darwin",
            "x86_64-pc-windows-gnu": "x86_64-pc-windows-gnu",
            "x86_64-unknown-linux-gnu": "x86_64-unknown-linux-gnu",
        },
        "url": "https://github.com/bytecodealliance/wasm-pkg-tools/releases/download/v{version}/wkg-{platform}",
        "ext": lambda p: "",
    },
    "binaryen": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "binaryen_releases",
        "platforms": {
            "aarch64-linux": "aarch64-linux",
            "arm64-macos": "arm64-macos",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
            "x86_64-windows": "x86_64-windows",
        },
        "url": "https://github.com/WebAssembly/binaryen/releases/download/version_{version}/binaryen-version_{version}-{platform}.tar.gz",
        "ext": lambda p: "tar.gz",
    },
    "wasmtime": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "wasmtime_releases",
        "platforms": {
            "aarch64-linux": "aarch64-linux",
            "aarch64-macos": "aarch64-macos",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
        },
        "url": "https://github.com/bytecodealliance/wasmtime/releases/download/v{version}/wasmtime-v{version}-{platform}.tar.xz",
        "ext": lambda p: "tar.xz",
    },
    "wasi-adapters": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "wasi_adapters",
        "version_prefix": "v",
        "types": {
            "reactor": "wasi_snapshot_preview1.reactor.wasm",
            "command": "wasi_snapshot_preview1.command.wasm",
        },
        "url": "https://github.com/bytecodealliance/wasmtime/releases/download/v{version}/{artifact}",
    },
    "node": {
        "file": "toolchains/node/releases.bzl",
        "extra_files": ["toolchains/wasm/node_releases.bzl"],
        "dict_name": "node_releases",
        "platforms": {
            "aarch64-linux": {"node_platform": "linux-arm64", "prefix": "node-v{version}-linux-arm64"},
            "aarch64-macos": {"node_platform": "darwin-arm64", "prefix": "node-v{version}-darwin-arm64"},
            "x86_64-linux": {"node_platform": "linux-x64", "prefix": "node-v{version}-linux-x64"},
            "x86_64-macos": {"node_platform": "darwin-x64", "prefix": "node-v{version}-darwin-x64"},
        },
        "url": "https://nodejs.org/dist/v{version}/node-v{version}-{node_platform}.tar.xz",
    },
    "wasi-sdk": {
        "file": "toolchains/cxx/wasi/releases.bzl",
        "dict_name": "releases",
        "url_key": "tarball",
        "platforms": {
            "arm64-linux": "arm64-linux",
            "arm64-macos": "arm64-macos",
            "arm64-windows": "arm64-windows",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
            "x86_64-windows": "x86_64-windows",
        },
        "url": "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-{major}/wasi-sdk-{version}-{platform}.tar.gz",
        "ext": lambda p: "tar.gz",
    },
}


def sha256_url(url: str) -> str:
    """Download a URL and return its SHA256 hex digest."""
    print(f"  Downloading {url} ...", end=" ", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "update-releases/1.0"})
    h = hashlib.sha256()
    with urllib.request.urlopen(req) as resp:
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            h.update(chunk)
    digest = h.hexdigest()
    print(f"sha256={digest[:16]}...")
    return digest


def build_entry_standard(tool_cfg: dict, version: str) -> dict:
    """Build a {platform: {shasum, url}} entry for standard tools."""
    entry = {}
    url_key = tool_cfg.get("url_key", "url")

    for plat_key, plat_val in tool_cfg["platforms"].items():
        if isinstance(plat_val, dict):
            # Node.js style with extra fields
            node_platform = plat_val["node_platform"]
            prefix = plat_val["prefix"].format(version=version)
            url = tool_cfg["url"].format(version=version, node_platform=node_platform)
            sha = sha256_url(url)
            entry[plat_key] = {
                "shasum": sha,
                url_key: url,
                "prefix": prefix,
            }
        else:
            # Standard: platform string used directly
            ext_fn = tool_cfg.get("ext", lambda p: "")
            ext = ext_fn(plat_val)
            fmt_kwargs = {
                "version": version,
                "platform": plat_val,
                "ext": ext,
                "major": version.split(".")[0] if "." in version else version,
            }
            url = tool_cfg["url"].format(**fmt_kwargs)
            sha = sha256_url(url)
            platform_entry = {"shasum": sha, url_key: url}
            entry[plat_key] = platform_entry

    return entry


def build_entry_wasi_adapters(tool_cfg: dict, version: str) -> dict:
    """Build a {type: {url, shasum}} entry for wasi_adapters."""
    entry = {}
    for type_key, artifact in tool_cfg["types"].items():
        url = tool_cfg["url"].format(version=version, artifact=artifact)
        sha = sha256_url(url)
        entry[type_key] = {"url": url, "shasum": sha}
    return entry


def format_entry(entry: dict, indent: int = 8) -> str:
    """Format a platform entry as a Starlark dict literal."""
    pad = " " * indent
    inner_pad = " " * (indent + 4)
    lines = []
    for key, val in entry.items():
        if isinstance(val, dict):
            lines.append(f'{pad}"{key}": {{')
            for k, v in val.items():
                lines.append(f'{inner_pad}"{k}": "{v}",')
            lines.append(f"{pad}}},")
    return "\n".join(lines)


def insert_version_entry(file_path: Path, dict_name: str, version_key: str, entry: dict):
    """Insert a new version entry at the top of the named dict in a .bzl file."""
    content = file_path.read_text()

    # Format the new entry
    entry_str = format_entry(entry)
    new_block = f'    "{version_key}": {{\n{entry_str}\n    }},'

    # Find the dict and insert after the opening brace
    # Pattern: `dict_name = {\n` — insert new entry right after
    pattern = rf"({re.escape(dict_name)}\s*=\s*\{{)\n"
    match = re.search(pattern, content)
    if not match:
        print(f"ERROR: Could not find '{dict_name}' dict in {file_path}")
        sys.exit(1)

    insert_pos = match.end()
    content = content[:insert_pos] + f"{new_block}\n" + content[insert_pos:]
    file_path.write_text(content)
    print(f"  Inserted {version_key} into {dict_name} in {file_path}")


def update_wasi_adapters_latest(file_path: Path, version: str, entry: dict):
    """Update the 'latest' alias in wasi_adapters to point to the new version."""
    content = file_path.read_text()

    # Build the latest entry (same data, different key)
    latest_str = format_entry(entry)
    new_latest = f'    "latest": {{\n{latest_str}\n    }},'

    # Replace existing latest block
    pattern = r'    "latest": \{[^}]*\{[^}]*\}[^}]*\{[^}]*\}\s*\},'
    if re.search(pattern, content):
        content = re.sub(pattern, new_latest, content)
        file_path.write_text(content)
        print(f'  Updated "latest" alias in wasi_adapters')
    else:
        print(f'  WARNING: Could not find "latest" block in wasi_adapters')


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    tool_name = sys.argv[1]
    version = sys.argv[2]

    if tool_name not in TOOLS and tool_name != "wasmtime":
        print(f"Unknown tool: {tool_name}")
        print(f"Available tools: {', '.join(TOOLS.keys())}")
        sys.exit(1)

    # Handle wasmtime specially: update both wasmtime_releases and wasi_adapters
    if tool_name == "wasmtime":
        print(f"\n=== Updating wasmtime {version} ===")
        cfg = TOOLS["wasmtime"]
        entry = build_entry_standard(cfg, version)
        file_path = REPO_ROOT / cfg["file"]
        insert_version_entry(file_path, cfg["dict_name"], version, entry)

        print(f"\n=== Updating wasi_adapters v{version} ===")
        adapter_cfg = TOOLS["wasi-adapters"]
        adapter_entry = build_entry_wasi_adapters(adapter_cfg, version)
        version_key = f"v{version}"
        insert_version_entry(file_path, adapter_cfg["dict_name"], version_key, adapter_entry)
        update_wasi_adapters_latest(file_path, version, adapter_entry)
        return

    cfg = TOOLS[tool_name]
    file_path = REPO_ROOT / cfg["file"]

    print(f"\n=== Updating {tool_name} {version} ===")

    if tool_name == "wasi-adapters":
        entry = build_entry_wasi_adapters(cfg, version)
        version_key = cfg.get("version_prefix", "") + version
    else:
        entry = build_entry_standard(cfg, version)
        version_key = version

    insert_version_entry(file_path, cfg["dict_name"], version_key, entry)

    # Handle extra files (e.g., node has two releases.bzl copies)
    for extra in cfg.get("extra_files", []):
        extra_path = REPO_ROOT / extra
        if extra_path.exists():
            insert_version_entry(extra_path, cfg["dict_name"], version_key, entry)


if __name__ == "__main__":
    main()
