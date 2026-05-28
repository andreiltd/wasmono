#!/usr/bin/env python3
"""Test that wasmono toolchains work when loaded as a git external cell.

Adapted from Buck2's external cell tests:
    https://github.com/facebook/buck2/blob/main/tests/core/external_cells/test_git.py

The approach mirrors Buck2's test_git pattern:
    1. Copy test fixture (external_cell_data/) into a temp workspace
    2. Set up a file:// git origin pointing at the wasmono repo snapshot
    3. Patch .buckconfig with git_origin + commit_hash
    4. Run buck2 targets + build to verify all loads resolve

Usage:
    ./tests/test_external_cell.py          # uses current worktree snapshot
    ./tests/test_external_cell.py <sha>    # uses specific commit
"""

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
            # Verify target resolution
            print("\n--- Verifying target resolution ---")
            res = _buck2(["targets", "//..."], workspace)
            print(res.stderr)

            if res.returncode != 0:
                print("FAILED: buck2 targets //...")
                print(res.stderr)
                return 1

            # Build genrules to verify toolchain setup and transition refs.
            print("--- Building genrules to verify toolchain setup ---")
            res = _buck2(
                ["build", "//:check", "//:check_wasip1_transition"],
                workspace,
            )
            print(res.stderr)

            if res.returncode != 0:
                print(
                    "FAILED: buck2 build "
                    "//:check //:check_wasip1_transition"
                )
                print(res.stderr)
                return 1
        finally:
            # Kill daemon so temp dir can be cleaned up
            _buck2(["kill"], workspace)

        print("=== External cell test PASSED ===")
        return 0


if __name__ == "__main__":
    sys.exit(main())
