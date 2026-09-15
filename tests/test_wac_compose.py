#!/usr/bin/env python3
"""Tests for composition with explicitly declared WAC dependencies."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "wac_compose", ROOT / "tools/wac_compose.py"
)
wac_compose = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(wac_compose)


def package(name, version=None):
    return {"string": name, "name": name, "version": version, "span": {}}


def document(*references):
    return {
        "directive": {"package": package("test:composition")},
        "statements": [{"Let": {"package": ref}} for ref in references],
    }


class TestWacDependencies(unittest.TestCase):
    def test_collects_nested_and_target_package_references(self):
        ast = document(package("test:plug"), package("test:plug"))
        ast["directive"]["targets"] = {
            **package("test:target", "1.2.3"),
            "segments": "world",
        }
        ast["statements"].append(
            {"Type": {"Use": {"path": package("test:types", "2.0.0")}}}
        )
        self.assertEqual(
            wac_compose._document_refs(ast),
            [("test:target", "1.2.3"), ("test:plug", None), ("test:types", "2.0.0")],
        )

    def test_rejects_unrecognized_or_unsafe_parser_output(self):
        for ast in (
            [],
            {"statements": []},
            document(package("../test:plug")),
            document(package("test:plug", "../../escape")),
        ):
            with self.subTest(ast=ast), self.assertRaises(ValueError):
                wac_compose._document_refs(ast)

    def test_versioned_mapping_takes_precedence(self):
        base = Path("base.wasm")
        exact = Path("exact.wasm")
        self.assertEqual(
            wac_compose._bind_dependencies(
                [("test:plug", "1.2.3"), ("test:plug", "2.0.0")],
                {"test:plug": base, "test:plug@1.2.3": exact},
            ),
            [("test:plug", "1.2.3", exact), ("test:plug", "2.0.0", base)],
        )

    def test_missing_dependency_has_migration_message(self):
        with self.assertRaisesRegex(
            ValueError, "explicit deps for: test:plug@1.2.3"
        ):
            wac_compose._bind_dependencies([("test:plug", "1.2.3")], {})

    def test_mapping_validation_and_paths_with_equals(self):
        with tempfile.TemporaryDirectory() as temp:
            artifact = Path(temp) / "with=equals.wasm"
            artifact.write_bytes(b"component")
            mapping = f"test:plug={artifact}"
            self.assertEqual(
                wac_compose._declared_dependencies([mapping]),
                {"test:plug": artifact},
            )

            for mappings in (
                [mapping, mapping],
                ["test:plug"],
                ["test:plug="],
                [f"test:plug={temp}/missing.wasm"],
            ):
                with self.subTest(mappings=mappings), self.assertRaises(ValueError):
                    wac_compose._declared_dependencies(mappings)

    def test_composes_with_private_versioned_dependencies(self):
        with tempfile.TemporaryDirectory() as temp:
            artifact = Path(temp) / "input with spaces.wasm"
            artifact.write_bytes(b"component")
            output = Path(temp) / "result.wasm"
            ast = document(package("test:plug"), package("test:plug", "1.2.3"))
            commands = []
            staging = []

            def run(command, **kwargs):
                commands.append(command)
                self.assertFalse(kwargs["check"])

                if "parse" in command:
                    return subprocess.CompletedProcess(command, 0, json.dumps(ast))

                deps_dir = Path(command[command.index("--deps-dir") + 1])
                staging.append(deps_dir)
                self.assertEqual(
                    (deps_dir / "test/plug/1.2.3.wasm").read_bytes(), b"component"
                )
                self.assertIn(f"test:plug={artifact}", command)
                self.assertNotIn("--registry", command)
                output.write_bytes(b"composed")
                return subprocess.CompletedProcess(command, 0)

            argv = [
                "wac_compose.py", "--source", "input.wac", "--output", str(output),
                "--dep", f"test:plug={artifact}", "--", "python", "custom-wac.py",
            ]

            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(wac_compose.subprocess, "run", side_effect=run),
            ):
                self.assertEqual(wac_compose.main(), 0)

            self.assertEqual(commands[0], ["python", "custom-wac.py", "parse", "input.wac"])
            self.assertEqual(commands[1][:3], ["python", "custom-wac.py", "compose"])
            self.assertEqual(output.read_bytes(), b"composed")
            self.assertFalse(staging[0].exists())
            self.assertEqual(artifact.read_bytes(), b"component")

    def test_missing_dependencies_never_invoke_composition(self):
        argv = ["wac_compose.py", "--source", "input.wac", "--output", "out", "--", "wac"]
        parsed = subprocess.CompletedProcess(
            ["wac"], 0, json.dumps(document(package("test:missing")))
        )

        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.object(wac_compose.subprocess, "run", return_value=parsed) as run,
        ):
            self.assertEqual(wac_compose.main(), 1)

        run.assert_called_once()

    def test_parser_failure_and_invalid_json_do_not_compose(self):
        argv = ["wac_compose.py", "--source", "input.wac", "--output", "out", "--", "wac"]

        for status, stdout, expected in ((2, "", 2), (0, "invalid JSON", 1)):
            with (
                self.subTest(status=status),
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(
                    wac_compose.subprocess, "run",
                    return_value=subprocess.CompletedProcess(["wac"], status, stdout),
                ) as run,
            ):
                self.assertEqual(wac_compose.main(), expected)

            run.assert_called_once()

    def test_composition_failure_is_propagated(self):
        argv = ["wac_compose.py", "--source", "input.wac", "--output", "out", "--", "wac"]

        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.object(
                wac_compose.subprocess, "run",
                side_effect=[
                    subprocess.CompletedProcess(["wac"], 0, json.dumps(document())),
                    subprocess.CompletedProcess(["wac"], 7),
                ],
            ),
        ):
            self.assertEqual(wac_compose.main(), 7)


if __name__ == "__main__":
    unittest.main()
