from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from evals.runner.models import MemorySpec


@dataclass(slots=True)
class ConditionContext:
    condition: str
    workspace: Path
    trial_dir: Path
    project_id: str
    hypermnesia_bin: str
    mcp_config_path: Path
    memory_seed: list["MemorySpec"]


@dataclass(slots=True)
class ConditionSetup:
    """Everything the runner needs after a condition is set up."""

    env: dict[str, str]
    effective_prompt: str          # task prompt, possibly augmented (oracle)
    injected_context: str          # what memory would inject (manipulation check); "" if none
    seeded_count: int = 0
    notes: list[str] = field(default_factory=list)


def _run(args: list[str], cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True, env=env)


def _isolated_support_dir(ctx: ConditionContext) -> Path:
    """A per-trial Hypermnesia data dir. NEVER the user's real store."""
    return ctx.trial_dir / "ht_home"


def _base_env(ctx: ConditionContext) -> dict[str, str]:
    env = dict(os.environ)
    support = _isolated_support_dir(ctx)
    support.mkdir(parents=True, exist_ok=True)
    env["HYPERMNESIA_SUPPORT_DIR"] = str(support)
    return env


def _seed_store(ctx: ConditionContext, env: dict[str, str]) -> int:
    """Load the task's memories into the isolated store under the pinned project id."""
    if not ctx.memory_seed:
        return 0
    seed_path = ctx.trial_dir / "memory_seed.json"
    seed_path.write_text(
        json.dumps([m.to_seed_dict() for m in ctx.memory_seed], indent=2), encoding="utf-8"
    )
    _run(
        [ctx.hypermnesia_bin, "seed-memories", "--file", str(seed_path), "--project", ctx.project_id],
        cwd=ctx.workspace, env=env,
    )
    return len(ctx.memory_seed)


def dry_hydrate(ctx: ConditionContext, env: dict[str, str]) -> str:
    """Run the hydrate hook against the (seeded, isolated) store exactly as a SessionStart would,
    and return the `additionalContext` it produces. This is the manipulation check: it proves the
    seed + project id + mechanism are wired, and yields the exact text injected at session start."""
    payload = json.dumps({"hook_event_name": "SessionStart", "cwd": str(ctx.workspace)})
    proc = subprocess.run(
        [ctx.hypermnesia_bin, "hydrate"],
        cwd=ctx.workspace, input=payload, capture_output=True, text=True, env=env,
    )
    out = proc.stdout.strip()
    if not out:
        return ""
    try:
        parsed = json.loads(out)
        return parsed.get("hookSpecificOutput", {}).get("additionalContext", "") or ""
    except json.JSONDecodeError:
        return ""


def dry_hydrate_prompt(ctx: ConditionContext, env: dict[str, str], prompt: str) -> str:
    """Like dry_hydrate, but exercises the per-prompt (UserPromptSubmit) relevance-ranked path with
    the task prompt — the manipulation check for hooks_relevance (what semantic retrieval surfaces)."""
    payload = json.dumps({"hook_event_name": "UserPromptSubmit", "cwd": str(ctx.workspace), "prompt": prompt})
    proc = subprocess.run(
        [ctx.hypermnesia_bin, "hydrate"],
        cwd=ctx.workspace, input=payload, capture_output=True, text=True, env=env,
    )
    out = proc.stdout.strip()
    if not out:
        return ""
    try:
        return json.loads(out).get("hookSpecificOutput", {}).get("additionalContext", "") or ""
    except json.JSONDecodeError:
        return ""


def setup_condition(ctx: ConditionContext, task_prompt: str) -> ConditionSetup:
    bin_path = shutil.which(ctx.hypermnesia_bin)
    # Every condition except the baseline control invokes the CLI (seed-memories, install-hooks,
    # hydrate, install-memory-guide, backfill) — fail early and clearly if it's missing rather than
    # deep inside a subprocess call with a worse error.
    if ctx.condition != "baseline" and not bin_path:
        raise RuntimeError(
            f"Hypermnesia binary '{ctx.hypermnesia_bin}' not found on PATH. "
            "Set HYPERMNESIA_BIN or install the CLI."
        )

    teardown_condition(ctx)
    env = _base_env(ctx)

    if ctx.condition == "baseline":
        return ConditionSetup(env=env, effective_prompt=task_prompt, injected_context="")

    if ctx.condition == "hooks_only":
        seeded = _seed_store(ctx, env)
        _run([ctx.hypermnesia_bin, "install-hooks", "--project", str(ctx.workspace)], cwd=ctx.workspace, env=env)
        injected = dry_hydrate(ctx, env)
        notes = [] if injected else ["WARNING: hydrate produced no context — memory will not fire"]
        return ConditionSetup(env=env, effective_prompt=task_prompt, injected_context=injected,
                              seeded_count=seeded, notes=notes)

    if ctx.condition == "hooks_relevance":
        seeded = _seed_store(ctx, env)
        # Disable SessionStart inject-all; rely only on per-prompt semantic-ranked injection so that
        # memories irrelevant to the current task (the near-miss harm vector) are never surfaced.
        support = _isolated_support_dir(ctx)
        support.mkdir(parents=True, exist_ok=True)
        (support / "config.json").write_text(
            json.dumps({"injectAtSessionStart": False, "injectPerPrompt": True}), encoding="utf-8"
        )
        _run([ctx.hypermnesia_bin, "install-hooks", "--project", str(ctx.workspace)], cwd=ctx.workspace, env=env)
        injected = dry_hydrate_prompt(ctx, env, task_prompt)
        notes = ["per-prompt relevance-ranked injection (SessionStart inject-all disabled)"]
        if not injected:
            notes.append("note: nothing cleared the relevance threshold for this prompt")
        return ConditionSetup(env=env, effective_prompt=task_prompt, injected_context=injected,
                              seeded_count=seeded, notes=notes)

    if ctx.condition == "mcp_only":
        seeded = _seed_store(ctx, env)
        mcp_config = {
            "mcpServers": {
                "hypermnesia": {"command": ctx.hypermnesia_bin, "args": ["mcp"]}
            }
        }
        ctx.mcp_config_path.write_text(json.dumps(mcp_config, indent=2), encoding="utf-8")
        # Note: we do NOT set HYPERMNESIA_DISABLE — that flag only gates hooks, and there are none here.
        return ConditionSetup(env=env, effective_prompt=task_prompt, injected_context="",
                              seeded_count=seeded, notes=["recall is agent-initiated; see recall_calls metric"])

    if ctx.condition == "mcp_nudged":
        seeded = _seed_store(ctx, env)
        mcp_config = {"mcpServers": {"hypermnesia": {"command": ctx.hypermnesia_bin, "args": ["mcp"]}}}
        ctx.mcp_config_path.write_text(json.dumps(mcp_config, indent=2), encoding="utf-8")
        # The "pull with a nudge" path: install-memory-guide writes a CLAUDE.md block (auto-loaded
        # by Claude Code) that tells the agent to call recall before editing.  Using the real
        # installer validates the product command and keeps the eval honest.
        _run(
            [ctx.hypermnesia_bin, "install-memory-guide", "--project", str(ctx.workspace)],
            cwd=ctx.workspace, env=env,
        )
        return ConditionSetup(env=env, effective_prompt=task_prompt, injected_context="",
                              seeded_count=seeded, notes=["mcp + CLAUDE.md nudge via install-memory-guide"])

    if ctx.condition == "earned_hooks":
        # Install hooks but seed NOTHING — memories are earned via warmup sessions + backfill, which
        # the runner drives after setup. injected_context is filled in then (post-warmup dry-hydrate).
        _run([ctx.hypermnesia_bin, "install-hooks", "--project", str(ctx.workspace)], cwd=ctx.workspace, env=env)
        return ConditionSetup(env=env, effective_prompt=task_prompt, injected_context="",
                              notes=["memory earned via warmup+backfill; see injected_context after warmups"])

    if ctx.condition == "oracle":
        # Seed an isolated store only so we can render the IDENTICAL block hooks_only would inject,
        # then paste it straight into the prompt. No hooks, no MCP — pure upper bound on the knowledge.
        seeded = _seed_store(ctx, env)
        block = dry_hydrate(ctx, env)
        prompt = task_prompt if not block else (
            f"{block}\n\n---\n\nUsing the project memory above where relevant, complete this task:\n\n{task_prompt}"
        )
        return ConditionSetup(env=env, effective_prompt=prompt, injected_context=block, seeded_count=seeded)

    raise ValueError(f"Unknown condition: {ctx.condition}")


def teardown_condition(ctx: ConditionContext) -> None:
    hooks_json = ctx.workspace / ".claude" / "settings.json"
    if hooks_json.exists():
        try:
            _run(
                [ctx.hypermnesia_bin, "install-hooks", "--project", str(ctx.workspace), "--uninstall"],
                cwd=ctx.workspace,
            )
        except Exception:
            hooks_json.unlink(missing_ok=True)
    if ctx.mcp_config_path.exists():
        ctx.mcp_config_path.unlink()
    # Clean up any CLAUDE.md block written by install-memory-guide.
    claude_md = ctx.workspace / "CLAUDE.md"
    if claude_md.exists() and "hypermnesia:memory-guide" in claude_md.read_text(encoding="utf-8"):
        try:
            _run(
                [ctx.hypermnesia_bin, "install-memory-guide", "--project", str(ctx.workspace), "--uninstall"],
                cwd=ctx.workspace,
            )
        except Exception:
            claude_md.unlink(missing_ok=True)


def assert_condition_clean(ctx: ConditionContext, setup: ConditionSetup) -> None:
    # Isolation invariant for EVERY condition: the store must live inside the trial dir.
    support = setup.env.get("HYPERMNESIA_SUPPORT_DIR", "")
    if str(ctx.trial_dir) not in support:
        raise RuntimeError(f"store not isolated to trial dir (HYPERMNESIA_SUPPORT_DIR={support!r})")

    hooks_json = ctx.workspace / ".claude" / "settings.json"
    hooks_text = hooks_json.read_text(encoding="utf-8") if hooks_json.exists() else ""
    # install-hooks writes the binary as a quoted absolute path ("…/hypermnesia' hydrate"), so
    # match the binary name + subcommand rather than the literal "hypermnesia hydrate".
    has_hooks = bool(re.search(r"hypermnesia[^\n]{0,4}\s(hydrate|capture)", hooks_text))
    has_mcp = ctx.mcp_config_path.exists()

    if ctx.condition == "baseline":
        if has_hooks or has_mcp:
            raise RuntimeError("baseline contamination detected")
    elif ctx.condition in {"hooks_only", "earned_hooks", "hooks_relevance"}:
        if not has_hooks or has_mcp:
            raise RuntimeError(f"{ctx.condition} preflight failed")
    elif ctx.condition in {"mcp_only", "mcp_nudged"}:
        if has_hooks or not has_mcp:
            raise RuntimeError("mcp_only preflight failed")
    elif ctx.condition == "oracle":
        if has_hooks or has_mcp:
            raise RuntimeError("oracle preflight failed (should deliver via prompt only)")
    else:
        raise ValueError(f"Unknown condition: {ctx.condition}")
