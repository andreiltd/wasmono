#!/usr/bin/env python3
"""Focused tests for cross-platform action wrappers."""

import hashlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent


def _load_tool(name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


test_wrapper = _load_tool("test_wrapper")
wkg_get = _load_tool("wkg_get")
wit_fetch = _load_tool("wit_fetch")


class TestWasiDirectoryIsolation(unittest.TestCase):
    def test_rewrites_only_matching_preopen_arguments(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.with.dot"
            source.mkdir()
            (source / "data.txt").write_text("ok", encoding="utf-8")
            scratch = root / "scratch"
            scratch.mkdir()
            mapping = f"{source}::/data"
            command = [
                "wasmtime",
                "--dir",
                mapping,
                "file.component.wasm",
                ".",
            ]

            rewritten = test_wrapper._isolate_dirs(
                command,
                [mapping],
                str(scratch),
                guest_args_count=1,
            )

            self.assertEqual(rewritten[1], "--dir")
            self.assertEqual(
                rewritten[2],
                f"{scratch / 'preopen-0'}::/data",
            )
            self.assertEqual(rewritten[3:], ["file.component.wasm", "."])
            self.assertEqual(command[2], mapping)
            self.assertEqual(
                (scratch / "preopen-0" / "data.txt").read_text(encoding="utf-8"),
                "ok",
            )
            (scratch / "preopen-0" / "data.txt").write_text(
                "isolated",
                encoding="utf-8",
            )
            self.assertEqual(
                (source / "data.txt").read_text(encoding="utf-8"),
                "ok",
            )

    def test_preserves_implicit_guest_path_spelling(self):
        for host in [".", "fixtures", "./fixtures", "fixtures/../fixtures", "fixtures/"]:
            with (
                self.subTest(host=host),
                mock.patch.object(test_wrapper.shutil, "copytree") as copytree,
            ):
                isolated_host = str(Path("scratch") / "preopen-0")
                rewritten = test_wrapper._isolate_dirs(
                    ["wasmtime", "--dir", host, "component"],
                    [host],
                    "scratch",
                    guest_args_count=0,
                )

                self.assertEqual(
                    rewritten,
                    ["wasmtime", "--dir", f"{isolated_host}::{host}", "component"],
                )
                copytree.assert_called_once_with(
                    host,
                    isolated_host,
                    symlinks=os.name != "nt",
                )

    def test_rewrites_runtime_forms_without_touching_guest_arguments(self):
        replacements = {
            "fixtures": "scratch/preopen-0::fixtures",
            "fixtures::/data": "scratch/preopen-1::/data",
        }
        prefix = [
            "launcher",
            "prefix.wasm",
            "--",
            "wasmtime",
            "run",
            "--dir",
            "fixtures",
            "--dir=fixtures::/data",
        ]
        expected_prefix = [
            *prefix[:6],
            replacements["fixtures"],
            f"--dir={replacements['fixtures::/data']}",
        ]

        for guest_args in [
            [],
            ["--dir", "fixtures", "--dir=fixtures::/data"],
            ["--", "--dir", "fixtures", "--dir=fixtures::/data"],
            ["--dir", "fixtures", "--", "--dir=fixtures::/data"],
        ]:
            for separator in [[], ["--"]]:
                with self.subTest(guest_args=guest_args, separator=separator):
                    suffix = ["component-without-extension", *guest_args]
                    command = prefix + separator + suffix
                    original = list(command)

                    rewritten = test_wrapper._rewrite_dir_args(
                        command,
                        replacements,
                        guest_args_count=len(guest_args),
                    )

                    self.assertEqual(
                        rewritten,
                        expected_prefix + separator + suffix,
                    )
                    self.assertEqual(command, original)

    def test_keeps_unknown_and_nonmatching_arguments(self):
        command = [
            "wasmtime",
            "--directory",
            "fixtures",
            "--directory=fixtures",
            "--other=--dir=fixtures",
            "--env",
            "DATA=fixtures",
            "--dir",
            "fixtures-backup",
            "--dir=./fixtures",
            "--dir=fixtures/nested",
            "component",
            "--dir",
            "fixtures",
        ]
        self.assertEqual(
            test_wrapper._rewrite_dir_args(
                command,
                {"fixtures": "scratch/preopen-0::fixtures"},
                guest_args_count=2,
            ),
            command,
        )

    def test_dir_option_does_not_consume_or_rewrite_module(self):
        for module in ["fixtures", "--dir=fixtures"]:
            for guest_args in [[], ["--dir", "fixtures"]]:
                with self.subTest(module=module, guest_args=guest_args):
                    command = ["wasmtime", "--dir", module, *guest_args]
                    self.assertEqual(
                        test_wrapper._rewrite_dir_args(
                            command,
                            {"fixtures": "scratch/preopen-0::fixtures"},
                            guest_args_count=len(guest_args),
                        ),
                        command,
                    )

    def test_does_not_reinterpret_dir_values_as_options(self):
        command = [
            "wasmtime",
            "--dir",
            "--dir=fixtures",
            "--dir=fixtures",
            "component",
        ]
        self.assertEqual(
            test_wrapper._rewrite_dir_args(
                command,
                {"fixtures": "scratch/preopen-0::fixtures"},
                guest_args_count=0,
            ),
            [
                "wasmtime",
                "--dir",
                "--dir=fixtures",
                "--dir=scratch/preopen-0::fixtures",
                "component",
            ],
        )

    def test_rejects_invalid_guest_argument_counts_before_copying(self):
        for command, count in [
            ([], 0),
            (["wasmtime"], 0),
            (["wasmtime", "component"], -1),
            (["wasmtime", "component"], 1),
            (["wasmtime", "component"], 2),
            (["wasmtime", "component"], 3),
        ]:
            with (
                self.subTest(command=command, count=count),
                mock.patch.object(test_wrapper.shutil, "copytree") as copytree,
            ):
                with self.assertRaisesRegex(ValueError, "--guest-args-count"):
                    test_wrapper._rewrite_dir_args(
                        command,
                        {},
                        guest_args_count=count,
                    )

                with self.assertRaisesRegex(ValueError, "--guest-args-count"):
                    test_wrapper._isolate_dirs(
                        command,
                        ["fixtures"],
                        "scratch",
                        guest_args_count=count,
                    )

                copytree.assert_not_called()

    def test_rejects_empty_mapping_sides(self):
        for mapping in ["", "::", "::/data", "fixtures::"]:
            with (
                self.subTest(mapping=mapping),
                self.assertRaisesRegex(ValueError, "invalid WASI directory mapping"),
            ):
                test_wrapper._split_dir_spec(mapping)

    def test_copy_errors_are_not_suppressed(self):
        with (
            mock.patch.object(
                test_wrapper.shutil,
                "copytree",
                side_effect=OSError("copy failed"),
            ),
            self.assertRaisesRegex(OSError, "copy failed"),
        ):
            test_wrapper._isolate_dirs(
                ["wasmtime", "--dir", "fixtures", "component"],
                ["fixtures"],
                "scratch",
                guest_args_count=0,
            )


class TestWasmTestWrapper(unittest.TestCase):
    def _run_wrapper(
        self,
        options: list[str],
        command: list[str],
        *,
        cwd: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "tools" / "test_wrapper.py"),
                *options,
                "--",
                *command,
            ],
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cli_isolation_preserves_mounts_and_guest_argv(self):
        for source_dir, mapping, guest in [
            (".", ".", "."),
            ("fixtures", "fixtures", "fixtures"),
            ("fixtures", "./fixtures", "./fixtures"),
            ("fixtures", "fixtures::/data", "/data"),
        ]:
            with (
                self.subTest(mapping=mapping),
                tempfile.TemporaryDirectory() as temp,
            ):
                root = Path(temp)
                source = root / source_dir
                source.mkdir(exist_ok=True)
                data = source / "data.txt"
                data.write_text("original", encoding="utf-8")
                guest_args = [
                    "--dir",
                    mapping,
                    f"--dir={mapping}",
                    "--",
                    "--dir",
                    mapping,
                    f"--dir={mapping}",
                ]
                suffix = ["component", *guest_args]
                script = (
                    "from pathlib import Path\n"
                    "import sys\n"
                    "assert sys.argv[1] == '--dir'\n"
                    "host, guest = sys.argv[2].split('::', 1)\n"
                    f"assert guest == {guest!r}\n"
                    "assert Path(host).name == 'preopen-0'\n"
                    "assert sys.argv[3] == '--dir=' + sys.argv[2]\n"
                    f"assert sys.argv[4:] == {suffix!r}\n"
                    "data = Path(host) / 'data.txt'\n"
                    "assert data.read_text(encoding='utf-8') == 'original'\n"
                    "data.write_text('isolated', encoding='utf-8')\n"
                    "sys.exit(7)\n"
                )

                result = self._run_wrapper(
                    [
                        "--guest-args-count",
                        str(len(guest_args)),
                        "--isolate-dir",
                        mapping,
                        "--expected-exit-code",
                        "7",
                    ],
                    [
                        sys.executable,
                        "-c",
                        script,
                        "--dir",
                        mapping,
                        f"--dir={mapping}",
                        *suffix,
                    ],
                    cwd=root,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")
                self.assertEqual(data.read_text(encoding="utf-8"), "original")

    def test_cli_requires_count_for_isolation(self):
        result = self._run_wrapper(
            ["--isolate-dir", "fixtures"],
            [sys.executable, "-c", "print('runtime ran')", "component"],
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr,
            "error: --guest-args-count is required with --isolate-dir\n",
        )
        self.assertEqual(result.stdout, "")

    def test_cli_rejects_invalid_counts(self):
        command = [sys.executable, "-c", "print('runtime ran')", "component"]

        for count, status, message in [
            ("-1", 1, "non-negative"),
            (str(len(command) - 1), 1, "too large"),
            (str(len(command)), 1, "too large"),
            (str(len(command) + 1), 1, "too large"),
            ("not-an-integer", 2, "invalid int value"),
        ]:
            for isolation in [[], ["--isolate-dir", "fixtures"]]:
                with self.subTest(count=count, isolation=isolation):
                    result = self._run_wrapper(
                        ["--guest-args-count", count, *isolation],
                        command,
                    )
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertIn("--guest-args-count", result.stderr)
                    self.assertIn(message, result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_cli_rejects_invalid_directory_mappings(self):
        for mapping in ["", "::", "::/data", "fixtures::"]:
            with self.subTest(mapping=mapping):
                result = self._run_wrapper(
                    ["--guest-args-count", "0", "--isolate-dir", mapping],
                    [sys.executable, "-c", "print('runtime ran')", "component"],
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(
                    result.stderr,
                    f"error: invalid WASI directory mapping: {mapping!r}\n",
                )
                self.assertEqual(result.stdout, "")

    def test_cli_preserves_expected_exit_behavior_without_isolation(self):
        for expected, actual, count, status, stderr in [
            (None, 0, None, 0, ""),
            (None, 3, None, 1, ""),
            (7, 7, None, 0, ""),
            (7, 0, None, 1, "expected exit code 7, got 0\n"),
            (7, 3, None, 1, "expected exit code 7, got 3\n"),
            (7, 7, 0, 0, ""),
            (7, 3, 0, 1, "expected exit code 7, got 3\n"),
        ]:
            with self.subTest(expected=expected, actual=actual, count=count):
                options = []
                command = [sys.executable, "-c", f"raise SystemExit({actual})"]

                if expected is not None:
                    options += ["--expected-exit-code", str(expected)]

                if count is not None:
                    options += ["--guest-args-count", str(count)]
                    command.append("component")

                result = self._run_wrapper(options, command)

                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, stderr)

    def test_cli_rejects_missing_command(self):
        result = self._run_wrapper([], [])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "error: no command specified\n")
        self.assertEqual(result.stdout, "")


class TestWitFetchWrapper(unittest.TestCase):
    def test_supports_legacy_and_positional_directory_interfaces(self):
        for help_text, directory_prefix in [
            ("Usage: wkg wit fetch [OPTIONS]\n  -d, --wit-dir <DIR>\n", ["--wit-dir"]),
            ("Usage: wkg wit fetch [OPTIONS] [DIR]\n", []),
        ]:
            with self.subTest(help=help_text), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source = root / "input.wit"
                source.write_text("package test:input;", encoding="utf-8")
                launcher = root / "custom wkg.py"
                launcher.touch()
                output = root / "output"
                argv = [
                    "wit_fetch.py", "--out-dir", "output", "--wit", "input.wit",
                    "--config", "config.toml", "--cache", "cache",
                    "--", sys.executable, "custom wkg.py", "wit",
                ]

                with (
                    mock.patch.object(sys, "argv", argv),
                    mock.patch.object(wit_fetch.os, "getcwd", return_value=str(root)),
                    mock.patch.object(
                        wit_fetch.subprocess, "run",
                        return_value=subprocess.CompletedProcess([], 0, help_text),
                    ) as probe,
                    mock.patch.object(wit_fetch.subprocess, "call", return_value=7) as fetch,
                ):
                    self.assertEqual(wit_fetch.main(), 7)

                prefix = [sys.executable, str(launcher), "wit"]
                probe.assert_called_once_with(
                    [*prefix, "fetch", "--help"],
                    stdout=subprocess.PIPE, text=True, check=False,
                )
                fetch.assert_called_once_with(
                    [
                        *prefix, "fetch", *directory_prefix, str(output),
                        "--config", str(root / "config.toml"),
                        "--cache", str(root / "cache"),
                    ],
                    cwd=str(root),
                )
                self.assertEqual(
                    (output / "input.wit").read_bytes(), source.read_bytes()
                )

    def test_rejects_failed_or_unknown_interfaces_without_fetching(self):
        for help_status, help_text, expected, message in [
            (9, "", 9, "could not inspect wkg wit fetch options"),
            (0, "Usage: wkg wit fetch [OPTIONS]\n", 1, "unsupported wkg wit fetch directory interface"),
        ]:
            with self.subTest(status=help_status), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source = root / "input.wit"
                source.touch()
                argv = [
                    "wit_fetch.py", "--out-dir", str(root / "output"),
                    "--wit", str(source), "--", "wkg", "wit",
                ]

                with (
                    mock.patch.object(sys, "argv", argv),
                    mock.patch.object(
                        wit_fetch.subprocess, "run",
                        return_value=subprocess.CompletedProcess([], help_status, help_text),
                    ),
                    mock.patch.object(wit_fetch.subprocess, "call") as fetch,
                    mock.patch.object(sys, "stderr", new_callable=io.StringIO) as stderr,
                ):
                    self.assertEqual(wit_fetch.main(), expected)

                fetch.assert_not_called()
                self.assertIn(message, stderr.getvalue())


class TestPackageDownloadWrapper(unittest.TestCase):
    def test_package_digest_is_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "package.wasm"
            content = b"component"
            digest = hashlib.sha256(content).hexdigest()
            script = (
                "from pathlib import Path; "
                f"Path({str(output)!r}).write_bytes({content!r})"
            )

            for expected, status in [(digest, 0), (digest.upper(), 0), ("0" * 64, 1)]:
                argv = [
                    "wkg_get.py",
                    "--output",
                    str(output),
                    "--sha256",
                    expected,
                    "--",
                    sys.executable,
                    "-c",
                    script,
                ]

                with (
                    self.subTest(digest=expected),
                    mock.patch.object(sys, "argv", argv),
                    mock.patch.object(sys, "stderr", new_callable=io.StringIO) as stderr,
                ):
                    self.assertEqual(wkg_get.main(), status)

                    if status:
                        self.assertIn("package SHA-256 mismatch", stderr.getvalue())
                    else:
                        self.assertEqual(stderr.getvalue(), "")

    def test_download_failure_is_propagated(self):
        argv = [
            "wkg_get.py", "--output", "unused.wasm", "--sha256", "0" * 64,
            "--", "wkg", "get", "test:package@1.2.3",
        ]

        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.object(
                wkg_get.subprocess, "run",
                return_value=subprocess.CompletedProcess(["wkg"], 7),
            ) as run,
        ):
            self.assertEqual(wkg_get.main(), 7)

        run.assert_called_once_with(["wkg", "get", "test:package@1.2.3"], check=False)

    def test_missing_command_is_rejected(self):
        with (
            mock.patch.object(sys, "argv", ["wkg_get.py", "--output", "unused.wasm"]),
            mock.patch.object(sys, "stderr", new_callable=io.StringIO) as stderr,
        ):
            self.assertEqual(wkg_get.main(), 1)

        self.assertEqual(stderr.getvalue(), "error: no wkg command specified\n")

    def test_missing_download_output_is_an_error(self):
        with tempfile.TemporaryDirectory() as temp:
            argv = [
                "wkg_get.py", "--output", str(Path(temp) / "missing.wasm"),
                "--sha256", "0" * 64, "--", "wkg", "get", "test:package@1.2.3",
            ]

            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(
                    wkg_get.subprocess, "run",
                    return_value=subprocess.CompletedProcess(["wkg"], 0),
                ),
                self.assertRaises(FileNotFoundError),
            ):
                wkg_get.main()


if __name__ == "__main__":
    unittest.main()
