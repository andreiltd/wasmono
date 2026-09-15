#!/usr/bin/env python3
"""Test that wasmono toolchains work when loaded as a git external cell.

Adapted from Buck2's external cell tests:
    https://github.com/facebook/buck2/blob/main/tests/core/external_cells/test_git.py

The approach mirrors Buck2's test_git pattern:
    1. Copy test fixture (external_cell_data/) into a temp workspace
    2. Set up a file:// git origin pointing at the wasmono repo snapshot
    3. Patch .buckconfig with git_origin + commit_hash
    4. Run focused build, runtime, and invalid-input checks

Usage:
    ./tests/test_external_cell.py          # uses current worktree snapshot
    ./tests/test_external_cell.py <sha>    # uses specific commit
"""

import json
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _git(args: list[str], cwd: Path) -> str:
    out = subprocess.check_output(
        ["git"] + args, cwd=cwd, stderr=subprocess.DEVNULL
    ).decode().strip()
    return out


def _set_revision(rev: str, repo: Path, buckconfig: Path) -> None:
    """Patch .buckconfig with git_origin and commit_hash.

    Mirrors Buck2's _set_revision() from test_git.py.
    """
    # file:// URIs need forward slashes; on Windows convert backslashes
    repo_uri = repo.as_posix()

    if sys.platform == "win32" and not repo_uri.startswith("/"):
        repo_uri = "/" + repo_uri

    text = buckconfig.read_text(encoding="utf-8")
    text = text.replace(
        "git_origin = <PLACEHOLDER>",
        f"git_origin = file://{repo_uri}",
    )
    text = text.replace(
        "commit_hash = <PLACEHOLDER>",
        f"commit_hash = {rev}",
    )
    buckconfig.write_text(text, encoding="utf-8")


def _copy_worktree_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)

    if src.is_symlink():
        dst.symlink_to(src.readlink())
    else:
        shutil.copy2(src, dst)


def _snapshot_worktree(repo: Path, snapshot: Path) -> str:
    """Create a git repo snapshot with tracked and untracked files."""
    snapshot.mkdir()
    files = subprocess.check_output(
        [
            "git",
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        cwd=repo,
    ).split(b"\0")

    for raw_path in files:
        if not raw_path:
            continue

        rel = Path(raw_path.decode())
        src = repo / rel

        if src.exists():
            _copy_worktree_file(src, snapshot / rel)

    subprocess.check_call(["git", "init", "--quiet"], cwd=snapshot)
    subprocess.check_call(
        ["git", "config", "user.email", "wasmono-test@example.invalid"],
        cwd=snapshot,
    )
    subprocess.check_call(
        ["git", "config", "user.name", "Wasmono Test"],
        cwd=snapshot,
    )
    subprocess.check_call(["git", "add", "."], cwd=snapshot)
    subprocess.check_call(
        ["git", "commit", "--quiet", "-m", "snapshot"],
        cwd=snapshot,
    )
    return _git(["rev-parse", "HEAD"], snapshot)


def _buck2(args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    buck2_path = str(cwd / "buck2")

    if sys.platform == "win32":
        # DotSlash files need to be invoked via `dotslash buck2` on Windows
        cmd = ["dotslash", buck2_path] + args
    else:
        cmd = [buck2_path] + args

    return subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        check=False,
        text=True,
    )


def _check(args: list[str], workspace: Path, *errors: str) -> str:
    result = _buck2(args, workspace)
    diagnostic = f"buck2 {' '.join(args)}\n{result.stdout}{result.stderr}"

    if errors:
        if result.returncode == 0:
            raise AssertionError(diagnostic)

        for error in errors:
            if error not in result.stderr:
                raise AssertionError(f"Expected {error!r}:\n{diagnostic}")
    elif result.returncode != 0:
        raise AssertionError(diagnostic)

    return result.stdout


def _verify_npm_execution_platforms(workspace: Path) -> None:
    package = "root//toolchain_regressions/execution_platforms"
    config = f"build.execution_platforms={package}:platforms"
    cases = [
        ("linux_arm64", "linux", {"aarch64", "arm64"}),
        ("windows_x86_64", "win32", {"amd64", "x86_64"}),
    ]

    for name, host_os, host_arches in cases:
        expected = (
            "prelude//platforms:default"
            if sys.platform == host_os and platform.machine().lower() in host_arches
            else f"{package}:{name}"
        )
        resolved = _check(
            [
                "audit", "execution-platform-resolution",
                "-c", config, f"{package}:{name}_consumer",
            ],
            workspace,
        )

        if f"  Execution platform: {expected}" not in resolved.splitlines():
            raise AssertionError(resolved)

        graph = _check(
            [
                "aquery", "%s",
                f"{package}:{name}_asc_dist", f"{package}:{name}_jco_dist",
                "--target-platforms", f"{package}:{name}",
                "-c", config,
                "--output-attribute", "^category$",
                "--output-attribute", "^executor_preference$",
                "--json",
            ],
            workspace,
        )

        actions = [
            value for value in json.loads(graph).values()
            if value.get("category") in {"npm_install_asc", "npm_install_jco"}
        ]

        if (
            len(actions) != 2
            or {action["category"] for action in actions} != {"npm_install_asc", "npm_install_jco"}
            or any(action.get("executor_preference") != "Default" for action in actions)
        ):
            raise AssertionError(actions)


def run_checks(workspace: Path) -> None:
    """Exercise the public rules without the workspace setup or teardown."""
    local = ["--local-only", "--no-remote-cache"]
    print("--- Building rule regressions ---", flush=True)
    _check(["targets", "//..."], workspace)
    _check(
        [
            "build", *local,
            "//:check",
            "//:check_wasip1_transition",
            "//:wasi_p1_command_component",
            "//rule_regressions:",
            "//toolchain_regressions:asc_flags",
        ],
        workspace,
    )

    print("--- Checking invalid inputs and package pinning ---", flush=True)
    failures = {
        "ambiguous_component": "found multiple component wasm",
        "empty_wit": "provides no WIT artifacts",
        "empty_binding_wit": "provides no WIT artifacts",
        "invalid_plug": "provides no component or core Wasm module",
        "empty_plugs": "'plugs' must contain at least one",
        "inline_registry": "inline registry inputs are no longer supported",
        "unpinned_package": "package must include an exact @version",
        "version_range": "package must include an exact @version",
        "invalid_digest": "expected_sha256 must contain exactly 64",
        "empty_distribution": "expected exactly one default output",
        "ambiguous_distribution": "expected exactly one default output",
    }

    for target, message in failures.items():
        _check(["audit", "providers", f"//rule_failures:{target}"], workspace, message)

    for target in [
        "pinned_package", "prerelease_package",
        "digest_pinned_package", "explicitly_unpinned_package",
        "default_only_wac", "default_only_wkg",
    ]:
        _check(["audit", "providers", f"//rule_failures:{target}"], workspace)

    for encoding in ["latin1", "compact-utf16"]:
        _check(
            [
                "audit", "providers", "//rule_failures:invalid_encoding",
                "-c", f"regressions.encoding={encoding}",
            ],
            workspace, "string_encoding", encoding,
        )

    _check(
        ["build", *local, "//rule_failures:undeclared_package"],
        workspace, "wasm_compose requires explicit deps for: undeclared:plug",
    )

    print("--- Running toolchain, linking, and isolation tests ---", flush=True)
    _check(
        ["test", *local, "//:directory_isolation", "//toolchain_regressions:tests"],
        workspace,
    )

    print("--- Checking npm execution platforms ---", flush=True)
    _verify_npm_execution_platforms(workspace)


def main() -> int:
    """Run the external-cell compatibility test."""
    repo = _repo_root()
    data_dir = repo / "tests" / "external_cell_data"

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        workspace = tmpdir / "workspace"

        if len(sys.argv) > 1:
            origin = repo
            commit = sys.argv[1]
        else:
            origin = tmpdir / "wasmono-snapshot"
            commit = _snapshot_worktree(repo, origin)

        print("=== External cell test ===")
        print(f"  repo:   {origin}")
        print(f"  commit: {commit}")
        print(f"  tmpdir: {workspace}")

        # Copy test fixture into workspace
        shutil.copytree(data_dir, workspace, dirs_exist_ok=True)
        shutil.copy2(repo / "buck2", workspace / "buck2")

        if sys.platform != "win32":
            (workspace / "buck2").chmod(0o755)

        # Patch .buckconfig (mirrors _set_revision)
        _set_revision(commit, origin, workspace / ".buckconfig")

        try:
            run_checks(workspace)
        finally:
            # Kill daemon so temp dir can be cleaned up
            _buck2(["kill"], workspace)

        print("=== External cell test PASSED ===")
        return 0


if __name__ == "__main__":
    sys.exit(main())
