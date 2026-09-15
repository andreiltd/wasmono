#!/usr/bin/env python3
# pylint: disable=invalid-name
"""Download release artifacts and update releases.bzl with new checksums.

Release dictionaries must be single top-level literal assignments. New entries
are inserted without rewriting existing metadata or comments.

Usage:
    python3 .github/scripts/update-releases.py <tool> <version>

Examples:
    python3 .github/scripts/update-releases.py wasm-tools 1.246.0
    python3 .github/scripts/update-releases.py wasmtime 43.0.0
    python3 .github/scripts/update-releases.py binaryen 126
    python3 .github/scripts/update-releases.py wasi-sdk 28.0
    python3 .github/scripts/update-releases.py node 22.0.0
"""

import ast
import hashlib
import sys
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
            "aarch64-windows": "aarch64-windows",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
            "x86_64-windows": "x86_64-windows",
        },
        "url": (
            "https://github.com/bytecodealliance/wasm-tools/releases/"
            "download/v{version}/wasm-tools-{version}-{platform}.{ext}"
        ),
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
        "url": (
            "https://github.com/bytecodealliance/wit-bindgen/releases/"
            "download/v{version}/wit-bindgen-{version}-{platform}.{ext}"
        ),
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
        "url": (
            "https://github.com/bytecodealliance/wac/releases/download/"
            "v{version}/wac-cli-{platform}"
        ),
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
        "url": (
            "https://github.com/bytecodealliance/wasm-pkg-tools/releases/"
            "download/v{version}/wkg-{platform}"
        ),
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
        "url": (
            "https://github.com/WebAssembly/binaryen/releases/download/"
            "version_{version}/binaryen-version_{version}-{platform}.tar.gz"
        ),
        "ext": lambda p: "tar.gz",
    },
    "wasmtime": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "wasmtime_releases",
        "platforms": {
            "aarch64-linux": "aarch64-linux",
            "aarch64-macos": "aarch64-macos",
            "aarch64-windows": "aarch64-windows",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
            "x86_64-windows": "x86_64-windows",
        },
        "url": (
            "https://github.com/bytecodealliance/wasmtime/releases/"
            "download/v{version}/wasmtime-v{version}-{platform}.{ext}"
        ),
        "ext": lambda p: "zip" if "windows" in p else "tar.xz",
    },
    "weval": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "weval_releases",
        "platforms": {
            "aarch64-linux": "aarch64-linux",
            "aarch64-macos": "aarch64-macos",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
            "x86_64-windows": "x86_64-windows",
        },
        "url": (
            "https://github.com/bytecodealliance/weval/releases/"
            "download/v{version}/weval-v{version}-{platform}.{ext}"
        ),
        "ext": lambda p: "zip" if "windows" in p else "tar.xz",
    },
    "wasi-adapters": {
        "file": "toolchains/wasm/releases.bzl",
        "dict_name": "wasi_adapters",
        "version_prefix": "v",
        "types": {
            "reactor": "wasi_snapshot_preview1.reactor.wasm",
            "command": "wasi_snapshot_preview1.command.wasm",
        },
        "url": (
            "https://github.com/bytecodealliance/wasmtime/releases/"
            "download/v{version}/{artifact}"
        ),
    },
    "node": {
        "file": "toolchains/node/releases.bzl",
        "extra_files": ["toolchains/wasm/node_releases.bzl"],
        "dict_name": "node_releases",
        "prefix": "node-v{version}-{platform}",
        "platforms": {
            "aarch64-linux": "linux-arm64",
            "aarch64-macos": "darwin-arm64",
            "aarch64-windows": "win-arm64",
            "x86_64-linux": "linux-x64",
            "x86_64-macos": "darwin-x64",
            "x86_64-windows": "win-x64",
        },
        "url": (
            "https://nodejs.org/dist/v{version}/"
            "node-v{version}-{platform}.{ext}"
        ),
        "ext": lambda p: "zip" if p.startswith("win-") else "tar.xz",
    },
    "wasi-sdk": {
        "file": "toolchains/cxx/wasi/releases.bzl",
        "dict_name": "releases",
        "url_key": "url",
        "artifact_version": lambda v: v if "." in v else f"{v}.0",
        "prefix": "wasi-sdk-{version}-{platform}/",
        "platforms": {
            "arm64-linux": "arm64-linux",
            "arm64-macos": "arm64-macos",
            "arm64-windows": "arm64-windows",
            "x86_64-linux": "x86_64-linux",
            "x86_64-macos": "x86_64-macos",
            "x86_64-windows": "x86_64-windows",
        },
        "url": (
            "https://github.com/WebAssembly/wasi-sdk/releases/download/"
            "wasi-sdk-{major}/wasi-sdk-{version}-{platform}.tar.gz"
        ),
        "ext": lambda p: "tar.gz",
    },
}


def sha256_url(url: str) -> str:
    """Download a URL and return its SHA256 hex digest."""
    print(f"  Downloading {url} ...", end=" ", flush=True)
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "update-releases/1.0"},
    )
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
    """Build platform entries with per-platform archives and optional prefixes."""
    entry = {}
    url_key = tool_cfg.get("url_key", "url")
    ext_fn = tool_cfg.get("ext", lambda p: "")
    artifact_version = tool_cfg.get("artifact_version", lambda v: v)(version)

    for plat_key, plat_val in tool_cfg["platforms"].items():
        fmt_kwargs = {
            "version": artifact_version,
            "platform": plat_val,
            "ext": ext_fn(plat_val),
            "major": version.split(".")[0],
        }
        url = tool_cfg["url"].format(**fmt_kwargs)
        sha = sha256_url(url)
        platform_entry = {"shasum": sha, url_key: url}

        if "prefix" in tool_cfg:
            platform_entry["prefix"] = tool_cfg["prefix"].format(**fmt_kwargs)

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


def _parse_release_dict(
        content: str,
        dict_name: str,
        file_path: Path) -> tuple[ast.Dict, dict]:
    """Locate and validate a literal release dictionary without executing it."""
    try:
        tree = ast.parse(content, filename=str(file_path))
    except SyntaxError as exc:
        raise ValueError(
            f"Malformed release file {file_path} while locating '{dict_name}': "
            f"{exc.msg} (line {exc.lineno})"
        ) from exc

    assignments = [
        node for node in tree.body
        if isinstance(node, ast.Assign)
        and any(
            isinstance(target, ast.Name) and target.id == dict_name
            for target in node.targets
        )
    ]

    if not assignments:
        raise ValueError(f"Missing '{dict_name}' dictionary in {file_path}")

    if len(assignments) != 1 or len(assignments[0].targets) != 1:
        raise ValueError(
            f"Expected a single assignment to '{dict_name}' in {file_path}"
        )

    node = assignments[0].value
    error = f"'{dict_name}' in {file_path} must be a literal dictionary"

    if not isinstance(node, ast.Dict):
        raise ValueError(error)  # noqa: TRY004 - malformed release-file content

    try:
        versions = ast.literal_eval(node)
    except (ValueError, TypeError) as exc:
        raise ValueError(error) from exc

    return node, versions


def insert_version_entry(
        file_path: Path,
        dict_name: str,
        version_key: str,
        entry: dict) -> None:
    """Insert into a literal .bzl dict, raising ValueError for invalid targets."""
    content = file_path.read_bytes()
    node, versions = _parse_release_dict(
        content.decode("utf-8"), dict_name, file_path,
    )

    if version_key in versions:
        print(f"  {version_key} already exists in {dict_name} in {file_path}")
        return

    # AST columns are UTF-8 byte offsets; splice bytes to preserve source exactly.
    lines = content.splitlines(keepends=True)
    line = lines[node.lineno - 1]
    insert_pos = sum(len(part) for part in lines[:node.lineno - 1])
    insert_pos += node.col_offset + 1
    tail = line[node.col_offset + 1:]
    newline = "\r\n" if b"\r\n" in content else "\n"
    new_block = f'    "{version_key}": {{\n{format_entry(entry)}\n    }},\n'

    if not tail.strip() or tail.lstrip().startswith(b"#"):
        # Keep whitespace and any comment on the opening-brace line in place.
        insert_pos += len(tail)
    else:
        new_block = "\n" + new_block

        if node.keys:
            new_block += "    "

    file_path.write_bytes(
        content[:insert_pos]
        + new_block.replace("\n", newline).encode("utf-8")
        + content[insert_pos:]
    )
    print(f"  Inserted {version_key} into {dict_name} in {file_path}")


def update_wasi_adapters_latest(
        file_path: Path,
        _version: str,
        entry: dict) -> None:
    """Update the 'latest' alias in wasi_adapters."""
    content = file_path.read_bytes()
    node, _ = _parse_release_dict(content.decode("utf-8"), "wasi_adapters", file_path)
    matches = [
        value for key, value in zip(node.keys, node.values)
        if isinstance(key, ast.Constant) and key.value == "latest"
    ]

    if len(matches) != 1:
        raise ValueError(
            f"Expected a single 'latest' entry in wasi_adapters in {file_path}"
        )

    value = matches[0]

    if not isinstance(value, ast.Dict):
        raise ValueError(  # noqa: TRY004 - malformed release-file content
            f"wasi_adapters['latest'] must be a literal dictionary in {file_path}"
        )

    lines = content.splitlines(keepends=True)
    start = sum(len(line) for line in lines[:value.lineno - 1]) + value.col_offset
    end = sum(len(line) for line in lines[:value.end_lineno - 1]) + value.end_col_offset
    line = lines[value.lineno - 1]
    indent = len(line) - len(line.lstrip(b" \t"))
    newline = "\r\n" if b"\r\n" in content else "\n"
    replacement = "{\n" + format_entry(entry, indent=indent + 4) + "\n" + " " * indent + "}"
    file_path.write_bytes(
        content[:start]
        + replacement.replace("\n", newline).encode("utf-8")
        + content[end:]
    )
    print('  Updated "latest" alias in wasi_adapters')


def main():
    """Update release metadata for a named tool version."""
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    tool_name = sys.argv[1]
    version = sys.argv[2]

    if tool_name not in TOOLS and tool_name != "wasmtime":
        print(f"Unknown tool: {tool_name}")
        print(f"Available tools: {', '.join(TOOLS.keys())}")
        sys.exit(1)

    # Wasmtime also owns the wasi-adapters release artifacts.
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
        insert_version_entry(
            file_path,
            adapter_cfg["dict_name"],
            version_key,
            adapter_entry,
        )
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
            insert_version_entry(
                extra_path,
                cfg["dict_name"],
                version_key,
                entry,
            )


if __name__ == "__main__":
    main()
