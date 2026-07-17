from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any


def _iter_events(stream_json_path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for line in stream_json_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def _content_blocks(event: dict[str, Any]) -> list[dict[str, Any]]:
    message = event.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if isinstance(content, list):
            return [b for b in content if isinstance(b, dict)]
    return []


def parse_stream_metrics(stream_json_path: Path) -> dict[str, Any]:
    """Pull authoritative metrics from the Claude Code stream.

    The final `type:"result"` event is the source of truth for turns/cost/usage — summing per-event
    usage double-counts under cumulative reporting + prompt caching, so we read the result event and
    only fall back to counting when it's absent (e.g. a hard timeout killed the run).
    """
    events = _iter_events(stream_json_path)

    assistant_messages = 0
    tool_use_count = 0
    recall_calls = 0          # agent-initiated Hypermnesia retrieval (mcp_only manipulation check)
    mcp_calls = 0
    tool_error_count = 0
    first_recall_seq: int | None = None   # tool-use ordinal of the first recall
    first_edit_seq: int | None = None     # tool-use ordinal of the first code edit
    _edit_tools = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
    result_event: dict[str, Any] | None = None

    for event in events:
        etype = event.get("type")
        if etype == "assistant":
            assistant_messages += 1
            for block in _content_blocks(event):
                if block.get("type") == "tool_use":
                    tool_use_count += 1
                    name = str(block.get("name", ""))
                    if name.startswith("mcp__hypermnesia"):
                        mcp_calls += 1
                        if "recall" in name or "ask" in name:
                            recall_calls += 1
                            if first_recall_seq is None:
                                first_recall_seq = tool_use_count
                    elif name in _edit_tools and first_edit_seq is None:
                        first_edit_seq = tool_use_count
        elif etype == "user":
            for block in _content_blocks(event):
                if block.get("type") == "tool_result" and block.get("is_error"):
                    tool_error_count += 1
        elif etype == "result":
            result_event = event

    metrics: dict[str, Any] = {
        "assistant_message_count": assistant_messages,
        "tool_use_count": tool_use_count,
        "mcp_calls": mcp_calls,
        "recall_calls": recall_calls,
        # Adoption telemetry: did the agent recall at all, and BEFORE its first code edit?
        "recalled": recall_calls > 0,
        "recall_before_first_edit": (
            first_recall_seq is not None
            and (first_edit_seq is None or first_recall_seq < first_edit_seq)
        ),
        "tool_error_count": tool_error_count,
        "completed": result_event is not None and not result_event.get("is_error", False),
        "result_subtype": (result_event or {}).get("subtype", "missing"),
    }

    if result_event is not None:
        usage = result_event.get("usage", {}) or {}
        metrics["num_turns"] = int(result_event.get("num_turns", 0) or 0)
        metrics["total_cost_usd"] = float(result_event.get("total_cost_usd", 0.0) or 0.0)
        metrics["duration_ms"] = int(result_event.get("duration_ms", 0) or 0)
        metrics["token_input"] = int(usage.get("input_tokens", 0) or 0)
        metrics["token_output"] = int(usage.get("output_tokens", 0) or 0)
        metrics["token_cache_read"] = int(usage.get("cache_read_input_tokens", 0) or 0)
        metrics["token_cache_creation"] = int(usage.get("cache_creation_input_tokens", 0) or 0)
    else:
        # No result event (timeout/crash): record None, NOT 0.0 — a misleading zero would make an
        # unstable condition look artificially cheap when these are averaged. Efficiency metrics
        # (cost/turns/duration) must EXCLUDE incomplete trials; `completed` flags them.
        metrics["num_turns"] = None
        metrics["total_cost_usd"] = None
        metrics["duration_ms"] = None
        metrics["token_input"] = None
        metrics["token_output"] = None
        metrics["token_cache_read"] = None
        metrics["token_cache_creation"] = None

    return metrics


def git_diff_stats(workspace: Path) -> tuple[int, int, int, str]:
    """Stage all of the agent's changes (incl. new files) and diff vs the seed commit.

    Must be called BEFORE held-out grader overlays are dropped in, so the diff reflects only the
    agent's work. `git diff HEAD` alone misses untracked new files, so we stage first.
    """
    subprocess.run(["git", "add", "-A"], cwd=workspace, check=True, capture_output=True, text=True)
    diff_proc = subprocess.run(
        ["git", "diff", "--cached", "HEAD"], cwd=workspace, check=True, capture_output=True, text=True
    )
    diff_text = diff_proc.stdout
    stat_proc = subprocess.run(
        ["git", "diff", "--cached", "HEAD", "--numstat"], cwd=workspace, check=True, capture_output=True, text=True
    )
    files = 0
    added = 0
    deleted = 0
    for line in stat_proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        added += int(parts[0]) if parts[0].isdigit() else 0
        deleted += int(parts[1]) if parts[1].isdigit() else 0
        files += 1
    return files, added, deleted, diff_text
