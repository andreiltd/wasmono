#!/usr/bin/env python3
"""Offline regression tests for release metadata generation and insertion."""

import ast
import hashlib
import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "update_releases", ROOT / ".github" / "scripts" / "update-releases.py",
)
assert SPEC is not None and SPEC.loader is not None
update_releases = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_releases)

SHA = "ab" * 32
ENTRY = {
    "x86_64-windows": {
        "shasum": SHA,
        "url": "https://example.invalid/tool.zip",
        "prefix": "tool",
    },
}
ENTRY_BLOCK = (
    '    "1.0.0": {\n'
    '        "x86_64-windows": {\n'
    f'            "shasum": "{SHA}",\n'
    '            "url": "https://example.invalid/tool.zip",\n'
    '            "prefix": "tool",\n'
    '        },\n'
    '    },\n'
)
NODE_ARCHIVES = {
    "aarch64-linux": ("linux-arm64", "tar.xz"),
    "aarch64-macos": ("darwin-arm64", "tar.xz"),
    "aarch64-windows": ("win-arm64", "zip"),
    "x86_64-linux": ("linux-x64", "tar.xz"),
    "x86_64-macos": ("darwin-x64", "tar.xz"),
    "x86_64-windows": ("win-x64", "zip"),
}


def _checksum(url: str) -> str:
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def _expected_node_entry(version: str) -> dict:
    entry = {}

    for key, (platform, extension) in NODE_ARCHIVES.items():
        prefix = f"node-v{version}-{platform}"
        url = f"https://nodejs.org/dist/v{version}/{prefix}.{extension}"
        entry[key] = {"shasum": _checksum(url), "url": url, "prefix": prefix}

    return entry


def _read_dict(path: Path, name: str) -> dict:
    tree = ast.parse(path.read_bytes())
    assignment = next(
        node for node in tree.body
        if isinstance(node, ast.Assign)
        and any(
            isinstance(target, ast.Name) and target.id == name
            for target in node.targets
        )
    )
    return ast.literal_eval(assignment.value)


class TestReleaseUpdates(unittest.TestCase):
    def setUp(self):
        self.contexts = ExitStack()
        self.addCleanup(self.contexts.close)
        self.root = Path(self.contexts.enter_context(tempfile.TemporaryDirectory()))
        self.sha256_url = self.contexts.enter_context(
            mock.patch.object(update_releases, "sha256_url", side_effect=_checksum)
        )
        self.contexts.enter_context(
            mock.patch.object(
                update_releases.urllib.request,
                "urlopen",
                side_effect=AssertionError("Release-update tests must not download"),
            )
        )
        self.output = io.StringIO()
        self.contexts.enter_context(redirect_stdout(self.output))

    def _write_source(self, source: str, relative: str = "releases.bzl") -> Path:
        path = self.root / relative
        self.assertTrue(path.resolve().is_relative_to(self.root.resolve()))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(source.encode("utf-8"))
        return path

    def _assert_invalid(self, source: str, message: str):
        path = self._write_source(source)

        with self.assertRaisesRegex(ValueError, message):
            update_releases.insert_version_entry(path, "target", "1.0.0", ENTRY)

        self.assertEqual(path.read_bytes(), source.encode("utf-8"))
        self.assertEqual(self.output.getvalue(), "")

    def test_historical_windows_checksums(self):
        cases = [
            (
                "toolchains/cxx/wasi/releases.bzl", "releases", "33.0", "arm64-windows",
                "2f457a62da1ce1a55e2ba77c450401b3551f27f04f0a87112b74c5aa8dd9504f",
            ),
            (
                "toolchains/wasm/releases.bzl", "wasm_tools_releases", "1.239.0", "x86_64-windows",
                "039b1eaa170563f762355a23c5ee709790199433e35e5364008521523e9e3398",
            ),
        ]

        for path, name, version, platform, checksum in cases:
            with self.subTest(path=path, version=version, platform=platform):
                self.assertEqual(
                    _read_dict(ROOT / path, name)[version][platform]["shasum"], checksum,
                )

    def test_node_windows_zip_archives(self):
        entry = update_releases.build_entry_standard(
            update_releases.TOOLS["node"], "26.8.2",
        )
        expected = _expected_node_entry("26.8.2")
        self.assertEqual(set(entry), set(NODE_ARCHIVES))

        for platform in ("aarch64-windows", "x86_64-windows"):
            with self.subTest(platform=platform):
                self.assertEqual(entry[platform], expected[platform])
                self.sha256_url.assert_any_call(expected[platform]["url"])

        self.assertEqual(self.sha256_url.call_count, 6)

    def test_node_unix_archives_are_unchanged(self):
        entry = update_releases.build_entry_standard(
            update_releases.TOOLS["node"], "24.16.0",
        )
        expected = _expected_node_entry("24.16.0")

        for platform in (
            "aarch64-linux", "aarch64-macos", "x86_64-linux", "x86_64-macos",
        ):
            with self.subTest(platform=platform):
                self.assertEqual(entry[platform], expected[platform])
                self.sha256_url.assert_any_call(expected[platform]["url"])

    def test_other_standard_tool_url_conventions_are_unchanged(self):
        cases = {
            "wasm-tools": (
                (
                    "https://github.com/bytecodealliance/wasm-tools/releases/"
                    "download/v1.2.3/wasm-tools-1.2.3-{platform}.{ext}"
                ),
                "tar.gz",
                "zip",
            ),
            "wit-bindgen": (
                (
                    "https://github.com/bytecodealliance/wit-bindgen/releases/"
                    "download/v1.2.3/wit-bindgen-1.2.3-{platform}.{ext}"
                ),
                "tar.gz",
                "zip",
            ),
            "wac": (
                (
                    "https://github.com/bytecodealliance/wac/releases/"
                    "download/v1.2.3/wac-cli-{platform}"
                ),
                "",
                "",
            ),
            "wkg": (
                (
                    "https://github.com/bytecodealliance/wasm-pkg-tools/releases/"
                    "download/v1.2.3/wkg-{platform}"
                ),
                "",
                "",
            ),
            "binaryen": (
                (
                    "https://github.com/WebAssembly/binaryen/releases/"
                    "download/version_1.2.3/binaryen-version_1.2.3-{platform}.{ext}"
                ),
                "tar.gz",
                "tar.gz",
            ),
            "wasmtime": (
                (
                    "https://github.com/bytecodealliance/wasmtime/releases/"
                    "download/v1.2.3/wasmtime-v1.2.3-{platform}.{ext}"
                ),
                "tar.xz",
                "zip",
            ),
            "weval": (
                (
                    "https://github.com/bytecodealliance/weval/releases/"
                    "download/v1.2.3/weval-v1.2.3-{platform}.{ext}"
                ),
                "tar.xz",
                "zip",
            ),
        }

        for tool, (template, unix_ext, windows_ext) in cases.items():
            cfg = update_releases.TOOLS[tool]
            entry = update_releases.build_entry_standard(cfg, "1.2.3")
            self.assertEqual(set(entry), set(cfg["platforms"]))

            for platform in cfg["platforms"]:
                with self.subTest(tool=tool, platform=platform):
                    extension = windows_ext if "windows" in platform else unix_ext
                    url = template.format(platform=platform, ext=extension)
                    self.assertEqual(
                        entry[platform], {"shasum": _checksum(url), "url": url},
                    )

    def test_preserves_windows_arm64_release_support(self):
        for tool in ("wasm-tools", "wasmtime"):
            with self.subTest(tool=tool):
                cfg = update_releases.TOOLS[tool]
                entry = update_releases.build_entry_standard(cfg, "1.2.3")
                self.assertIn("aarch64-windows", entry)
                url = entry["aarch64-windows"]["url"]
                self.assertTrue(url.endswith("-aarch64-windows.zip"))
                self.sha256_url.assert_any_call(url)

    def test_wasi_sdk_artifact_versions_and_prefixes_are_unchanged(self):
        for version, artifact_version in (("28", "28.0"), ("28.0", "28.0")):
            entry = update_releases.build_entry_standard(
                update_releases.TOOLS["wasi-sdk"], version,
            )

            for platform in update_releases.TOOLS["wasi-sdk"]["platforms"]:
                with self.subTest(version=version, platform=platform):
                    prefix = f"wasi-sdk-{artifact_version}-{platform}"
                    url = (
                        "https://github.com/WebAssembly/wasi-sdk/releases/"
                        f"download/wasi-sdk-28/{prefix}.tar.gz"
                    )
                    self.assertEqual(
                        entry[platform],
                        {"shasum": _checksum(url), "url": url, "prefix": prefix + "/"},
                    )

    def test_wasi_adapter_urls_are_unchanged(self):
        entry = update_releases.build_entry_wasi_adapters(
            update_releases.TOOLS["wasi-adapters"], "43.0.0",
        )
        expected = {}

        for kind in ("reactor", "command"):
            url = (
                "https://github.com/bytecodealliance/wasmtime/releases/"
                f"download/v43.0.0/wasi_snapshot_preview1.{kind}.wasm"
            )
            expected[kind] = {"url": url, "shasum": _checksum(url)}

        self.assertEqual(entry, expected)

    def test_wasi_adapter_latest_update_preserves_surrounding_source(self):
        old = '{"reactor": {"url": "old"}, "command": {"url": "old"},}'
        source = (
            "# Unicode offset: \u2603\n"
            "other = {'latest': {'keep': {}}}\n"
            "wasi_adapters = {\n"
            "    'v0': {'keep': {}},\n"
            f"    'latest': {old},  # retain this comment\n"
            "}\n"
        )
        replacement = "{\n" + update_releases.format_entry(ENTRY) + "\n    }"

        for newline in ("\n", "\r\n"):
            with self.subTest(newline=newline):
                original = source.replace("\n", newline)
                path = self._write_source(original)
                update_releases.update_wasi_adapters_latest(path, "1.0.0", ENTRY)
                self.assertEqual(
                    path.read_bytes(),
                    original.replace(old, replacement.replace("\n", newline)).encode("utf-8"),
                )
                self.assertEqual(_read_dict(path, "other"), {"latest": {"keep": {}}})
                self.assertEqual(
                    _read_dict(path, "wasi_adapters"),
                    {"v0": {"keep": {}}, "latest": ENTRY},
                )

    def test_wasi_adapter_latest_rejects_missing_or_ambiguous_alias(self):
        for source, message in (
            ("wasi_adapters = {}", "single 'latest' entry"),
            ("wasi_adapters = {'latest': {}, 'latest': {}}", "single 'latest' entry"),
            ("wasi_adapters = {'latest': 42}", "literal dictionary"),
        ):
            with self.subTest(source=source):
                path = self._write_source(source)

                with self.assertRaisesRegex(ValueError, message):
                    update_releases.update_wasi_adapters_latest(path, "1.0.0", ENTRY)

                self.assertEqual(path.read_bytes(), source.encode("utf-8"))

    def test_same_version_in_sibling_does_not_suppress_insertion(self):
        sibling = "first_tool_releases={'1.0.0': {'old': {}}}\n"
        path = self._write_source(sibling + "second_tool_releases={}\n")

        update_releases.insert_version_entry(
            path, "second_tool_releases", "1.0.0", ENTRY,
        )

        self.assertEqual(
            path.read_bytes(),
            (sibling + "second_tool_releases={\n" + ENTRY_BLOCK + "}\n").encode(),
        )
        self.assertEqual(_read_dict(path, "first_tool_releases"), {"1.0.0": {"old": {}}})
        self.assertEqual(_read_dict(path, "second_tool_releases"), {"1.0.0": ENTRY})

    def test_existing_same_dict_version_is_byte_identical(self):
        cases = (
            'target = {\n    "1.0.0": {},\n}\n',
            "target={'1.0.0': {}}",
            'target = {\r\n    "1.0.0": {},  # retain this\r\n}\r\n',
            'target = {"1." "0.0": {}}\n',
            'target = {"\\x31.0.0": {}}\n',
        )

        for source in cases:
            with self.subTest(source=source):
                path = self._write_source(source)
                update_releases.insert_version_entry(path, "target", "1.0.0", ENTRY)
                self.assertEqual(path.read_bytes(), source.encode("utf-8"))

    def test_nested_version_is_not_a_top_level_duplicate(self):
        source = 'target = {\n    "older": {"1.0.0": {}},\n}\n'
        path = self._write_source(source)

        update_releases.insert_version_entry(path, "target", "1.0.0", ENTRY)

        self.assertEqual(
            path.read_bytes(),
            source.replace("target = {\n", "target = {\n" + ENTRY_BLOCK).encode(),
        )
        self.assertEqual(
            _read_dict(path, "target"), {"1.0.0": ENTRY, "older": {"1.0.0": {}}},
        )

    def test_missing_target_fails_even_when_version_exists_elsewhere(self):
        self._assert_invalid(
            '"""target = {"1.0.0": {}}"""\n'
            'other = {"1.0.0": {}}\n'
            "not_target = {}\n"
            "def helper():\n"
            "    target = {}\n",
            "Missing 'target' dictionary",
        )

    def test_malformed_source_fails_without_writing(self):
        for source in (
            'other = {"1.0.0": {}}\ntarget = {\n',
            'target = {"1.0.0" {}}\n',
            'target = {"older": "unterminated}\n',
        ):
            with self.subTest(source=source):
                self._assert_invalid(source, "Malformed release file.*'target'")

    def test_nonliteral_targets_fail_without_writing(self):
        for value in (
            "[]",
            "dict()",
            '{"older": build_release()}',
            '{"1.0.0": build_release()}',
            "{**other}",
            "{version: {}}",
            "{[]: {}}",
            "{version: {} for version in versions}",
        ):
            with self.subTest(value=value):
                self._assert_invalid(
                    'other = {"1.0.0": {}}\ntarget = ' + value + "\n",
                    "'target'.*must be a literal dictionary",
                )

    def test_ambiguous_assignments_fail_without_writing(self):
        for source in (
            'target = {"1.0.0": {}}\ntarget = {}\n',
            "sibling = target = {}\n",
            "target = sibling = {}\n",
        ):
            with self.subTest(source=source):
                self._assert_invalid(source, "single assignment to 'target'")

    def test_preserves_siblings_comments_braces_and_strings(self):
        source = '''"""A fake target = {"1.0.0": {}} inside documentation."""
before = {"1.0.0": {"text": "} # {"}}
target = {  # Keep this header comment: } {
    # Keep this note attached to the old entry.
    "older": {
        "url": "https://example.invalid/{artifact}?closing=}",
        "quote": "escaped quote: \\" } # {",
        "notes": """Braces and a fake assignment:
target = {"1.0.0": {}}
}""",
    },
}
# Keep the following sibling unchanged.
after = {'1.0.0': {}, 'text': 'target = {}'}
'''
        path = self._write_source(source)
        before = _read_dict(path, "before")
        after = _read_dict(path, "after")
        existing = _read_dict(path, "target")

        update_releases.insert_version_entry(path, "target", "1.0.0", ENTRY)

        opening = "target = {  # Keep this header comment: } {\n"
        self.assertEqual(
            path.read_bytes(),
            source.replace(opening, opening + ENTRY_BLOCK, 1).encode("utf-8"),
        )
        self.assertEqual(_read_dict(path, "before"), before)
        self.assertEqual(_read_dict(path, "after"), after)
        self.assertEqual(_read_dict(path, "target"), {"1.0.0": ENTRY, **existing})

    def test_compact_and_parenthesized_dictionaries(self):
        cases = (
            ("target={}", "target={\n" + ENTRY_BLOCK + "}"),
            (
                "target = {'older': {}}  # trailing comment\n",
                "target = {\n" + ENTRY_BLOCK + "    'older': {}}  # trailing comment\n",
            ),
            (
                "target = (\n{\n    'older': {},\n}\n)\n",
                "target = (\n{\n" + ENTRY_BLOCK + "    'older': {},\n}\n)\n",
            ),
            (
                "before = {}; target={}; after = {}\n",
                "before = {}; target={\n" + ENTRY_BLOCK + "}; after = {}\n",
            ),
        )

        for source, expected in cases:
            with self.subTest(source=source):
                path = self._write_source(source)
                existing = _read_dict(path, "target")
                update_releases.insert_version_entry(path, "target", "1.0.0", ENTRY)
                self.assertEqual(path.read_bytes(), expected.encode("utf-8"))
                self.assertEqual(
                    _read_dict(path, "target"), {"1.0.0": ENTRY, **existing},
                )

    def test_preserves_utf8_offsets_and_crlf_line_endings(self):
        source = (
            "# A unicode comment: \u2603\r\n"
            "label = 'caf\u00e9 { }'; target={}; sibling = {'1.0.0': {}}\r\n"
        )
        path = self._write_source(source)

        update_releases.insert_version_entry(path, "target", "1.0.0", ENTRY)

        expected = source.replace(
            "target={}", "target={\r\n" + ENTRY_BLOCK.replace("\n", "\r\n") + "}",
        )
        self.assertEqual(path.read_bytes(), expected.encode("utf-8"))
        self.assertEqual(_read_dict(path, "target"), {"1.0.0": ENTRY})
        self.assertEqual(_read_dict(path, "sibling"), {"1.0.0": {}})

    def test_repository_release_formatting_on_temporary_copies(self):
        cases = {
            (relative, cfg["dict_name"])
            for cfg in update_releases.TOOLS.values()
            for relative in [cfg["file"], *cfg.get("extra_files", [])]
        }
        self.assertEqual(
            {relative for relative, _ in cases},
            {
                "toolchains/wasm/releases.bzl",
                "toolchains/wasm/node_releases.bzl",
                "toolchains/cxx/wasi/releases.bzl",
                "toolchains/node/releases.bzl",
            },
        )
        version = "0.0.0-release-update-test"
        block = ENTRY_BLOCK.replace('"1.0.0"', f'"{version}"', 1).encode("utf-8")

        for relative, name in sorted(cases):
            source_lf = (ROOT / relative).read_bytes().replace(b"\r\n", b"\n")

            for newline in (b"\n", b"\r\n"):
                with self.subTest(file=relative, dictionary=name, newline=newline):
                    source = source_lf.replace(b"\n", newline)
                    expected_block = block.replace(b"\n", newline)
                    path = self._write_source(source.decode("utf-8"), relative)
                    existing = _read_dict(path, name)
                    self.assertNotIn(version, existing)

                    update_releases.insert_version_entry(path, name, version, ENTRY)

                    updated = _read_dict(path, name)
                    updated_source = path.read_bytes()
                    self.assertEqual(updated, {version: ENTRY, **existing})
                    self.assertEqual(next(iter(updated)), version)
                    self.assertEqual(updated_source.count(expected_block), 1)
                    self.assertEqual(
                        updated_source.replace(expected_block, b"", 1), source,
                    )

    def test_node_main_updates_both_temporary_mirrors(self):
        cfg = update_releases.TOOLS["node"]
        version = "99.0.0"
        source = (
            '"""Temporary Node release metadata."""\n'
            'node_releases = {\n    "0.1.0": {},\n}\n'
            f'other_releases = {{"{version}": {{}}}}\n'
        )
        paths = [
            self._write_source(source, relative)
            for relative in [cfg["file"], *cfg["extra_files"]]
        ]

        with (
            mock.patch.object(update_releases, "REPO_ROOT", self.root),
            mock.patch.object(sys, "argv", ["update-releases.py", "node", version]),
        ):
            update_releases.main()

        self.assertEqual(len(paths), 2)
        self.assertEqual(paths[0].read_bytes(), paths[1].read_bytes())

        for path in paths:
            self.assertEqual(
                _read_dict(path, "node_releases"),
                {version: _expected_node_entry(version), "0.1.0": {}},
            )
            self.assertEqual(_read_dict(path, "other_releases"), {version: {}})

        self.assertEqual(self.sha256_url.call_count, 6)
        self.sha256_url.assert_has_calls(
            [mock.call(record["url"]) for record in _expected_node_entry(version).values()],
            any_order=True,
        )


if __name__ == "__main__":
    unittest.main()
