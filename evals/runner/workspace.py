from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


# A fixed fake remote so every trial's workspace resolves to the SAME Hypermnesia project id
# (github.com/eval/synthetic-webapp), regardless of its on-disk path. Without this, each trial dir
# would resolve to a different `path:/...` id and seeded memory would never be recalled.
PROJECT_REMOTE_URL = "https://github.com/eval/synthetic-webapp.git"
PROJECT_ID = "github.com/eval/synthetic-webapp"


def copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def apply_overlay(overlay_dir: Path, workspace: Path) -> None:
    """Copy every file under overlay_dir into workspace, preserving relative layout."""
    for source in overlay_dir.rglob("*"):
        rel = source.relative_to(overlay_dir)
        target = workspace / rel
        if source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def init_git_repo(workspace: Path) -> None:
    """Init a repo, pin the fake origin remote, and commit the seed so `git diff` is meaningful."""
    subprocess.run(["git", "init"], cwd=workspace, check=True, capture_output=True, text=True)
    subprocess.run(
        ["git", "remote", "add", "origin", PROJECT_REMOTE_URL],
        cwd=workspace, check=True, capture_output=True, text=True,
    )
    subprocess.run(["git", "add", "."], cwd=workspace, check=True, capture_output=True, text=True)
    subprocess.run(
        ["git", "-c", "user.name=eval", "-c", "user.email=eval@local", "commit", "-m", "seed"],
        cwd=workspace, check=True, capture_output=True, text=True,
    )


def ensure_shared_venv(runs_root: Path, requirements: list[str]) -> Path:
    """Create (once) a shared virtualenv for graders so we don't reinstall deps every trial.

    Returns the venv's bin directory; prepend it to PATH when running graders.
    """
    venv_dir = runs_root / ".venv-evals"
    bin_dir = venv_dir / ("Scripts" if sys.platform == "win32" else "bin")
    marker = venv_dir / ".installed"
    if marker.exists():
        return bin_dir

    subprocess.run([sys.executable, "-m", "venv", str(venv_dir)], check=True, capture_output=True, text=True)
    python = bin_dir / "python"
    subprocess.run([str(python), "-m", "pip", "install", "--upgrade", "pip"], check=True, capture_output=True, text=True)
    subprocess.run([str(python), "-m", "pip", "install", *requirements], check=True, capture_output=True, text=True)
    marker.write_text("ok\n", encoding="utf-8")
    return bin_dir
