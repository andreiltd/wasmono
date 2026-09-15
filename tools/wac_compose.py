#!/usr/bin/env python3
"""Compose WAC packages using only explicitly declared dependency artifacts."""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def _package_refs(node):
    if isinstance(node, dict):
        if "name" in node and "version" in node:
            name, version = node["name"], node["version"]

            if not isinstance(name, str) or not re.fullmatch(
                r"[A-Za-z0-9_-]+:[A-Za-z0-9_-]+", name
            ):
                raise ValueError("unsupported package name in WAC parser output")

            if version is not None and (
                not isinstance(version, str)
                or not re.fullmatch(r"[0-9A-Za-z.+-]+", version)
            ):
                raise ValueError("unsupported package version in WAC parser output")

            yield name, version

        for value in node.values():
            yield from _package_refs(value)
    elif isinstance(node, list):
        for value in node:
            yield from _package_refs(value)


def _document_refs(document) -> list[tuple[str, str | None]]:
    if not isinstance(document, dict) or not isinstance(
        document.get("statements"), list
    ):
        raise ValueError(  # noqa: TRY004 - malformed external parser output
            "unsupported WAC parser output: expected a document"
        )

    directive = document.get("directive")

    if not isinstance(directive, dict):
        raise ValueError(  # noqa: TRY004 - malformed external parser output
            "unsupported WAC parser output: missing package directive"
        )

    package = directive.get("package")

    if not isinstance(package, dict) or not isinstance(package.get("name"), str):
        raise ValueError(  # noqa: TRY004 - malformed external parser output
            "unsupported WAC parser output: missing package name"
        )

    own_name = package["name"]
    return list(
        dict.fromkeys(
            (name, version)
            for name, version in _package_refs(document)
            if name != own_name
        )
    )


def _declared_dependencies(specs: list[str]) -> dict[str, Path]:
    dependencies = {}

    for spec in specs:
        name, separator, path = spec.partition("=")

        if not separator or not name or not path:
            raise ValueError(f"invalid WAC dependency mapping: {spec!r}")

        if name in dependencies:
            raise ValueError(f"duplicate WAC dependency mapping: {name!r}")

        artifact = Path(path)

        if not artifact.is_file():
            raise ValueError(f"WAC dependency {name!r} is not a file: {path}")

        dependencies[name] = artifact

    return dependencies


def _bind_dependencies(
    refs: list[tuple[str, str | None]], dependencies: dict[str, Path]
) -> list[tuple[str, str | None, Path]]:
    bindings = []
    missing = []

    for name, version in refs:
        key = f"{name}@{version}" if version is not None else name
        artifact = dependencies.get(key, dependencies.get(name))

        if artifact is None:
            missing.append(key)
        else:
            bindings.append((name, version, artifact))

    if missing:
        raise ValueError(
            "wasm_compose requires explicit deps for: "
            + ", ".join(missing)
            + "; use pinned wasm_package targets for registry packages"
        )

    return bindings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--dep", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command

    if command and command[0] == "--":
        command = command[1:]

    if not command:
        parser.error("no WAC command specified")

    parsed = subprocess.run(
        [*command, "parse", args.source],
        stdout=subprocess.PIPE,
        text=True,
        check=False,
    )

    if parsed.returncode != 0:
        return parsed.returncode

    try:
        references = _document_refs(json.loads(parsed.stdout))
        dependencies = _declared_dependencies(args.dep)
        bindings = _bind_dependencies(references, dependencies)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="wasmono-wac-") as temp:
        compose = [*command, "compose", args.source, "--deps-dir", temp]

        for name, version, artifact in bindings:
            if version is None:
                compose.extend(["--dep", f"{name}={artifact}"])
            else:
                # WAC ignores --dep overrides for version-qualified references.
                path = Path(temp).joinpath(*name.split(":"), f"{version}.wasm")
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(artifact, path)

        compose.extend(["--output", args.output])
        return subprocess.run(compose, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
