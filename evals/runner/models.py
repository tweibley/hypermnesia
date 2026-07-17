from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# Experimental conditions:
#   baseline   — isolated empty store, no hooks, no MCP. The control.
#   hooks_only — isolated store seeded with the task's memories; Hypermnesia hydrate hooks inject
#                them at SessionStart/UserPromptSubmit. Tests the *automatic* delivery mechanism.
#   mcp_only   — isolated store seeded; Hypermnesia MCP server available (recall/ask/remember),
#                no hooks. Tests *agent-initiated* retrieval (the agent must choose to recall).
#   oracle     — no hooks/MCP; the same memory block is pasted directly into the prompt. An upper
#                bound: how much would the knowledge help if delivery were perfect? Lets us separate
#                "is the knowledge useful" from "does the delivery mechanism work".
#   earned_hooks — NOTHING is hand-seeded. Before the measured task, the agent completes warmup
#                  session(s) whose transcripts are replayed into memory via the real capture→drain
#                  classifier (Gemini), then hydrate hooks inject those *earned* memories. This is the
#                  full longitudinal loop — realistic, but nondeterministic (a model captures the memory).
#   hooks_relevance — hooks installed + store seeded, but SessionStart inject-all is DISABLED
#                     (config injectAtSessionStart=false); only per-prompt semantic-ranked injection
#                     fires, so memories irrelevant to the task are never surfaced. Tests whether
#                     retrieval relevance avoids near-miss over-application while keeping uplift.
#   mcp_nudged    — mcp_only + a CLAUDE.md instruction telling the agent to call recall before editing
#                   (the no-hooks "pull" path with a lightweight nudge, since the eval showed agents
#                   never initiate MCP recall on their own no matter how the tool is described).
CONDITIONS = ("baseline", "hooks_only", "mcp_only", "oracle", "earned_hooks", "hooks_relevance", "mcp_nudged")

# Task families — each measures a different facet of memory's value:
#   memory_critical — success requires knowledge that lives ONLY in seeded memory (held-out tests).
#   memory_efficiency — solvable without memory, but memory should reduce turns/tokens at equal success.
#   guardrail — self-contained; memory is irrelevant. Checks no-harm + injection overhead.
#   distractor — store seeded with plausible-but-irrelevant memories; checks memory doesn't mislead.
FAMILIES = ("memory_critical", "memory_efficiency", "guardrail", "distractor")


@dataclass(slots=True)
class MemorySpec:
    """One seeded memory. Mirrors `hypermnesia seed-memories` input."""

    type: str
    title: str
    summary: str
    confidence: float = 1.0
    status: str = "confirmed"
    applies_when: str | None = None
    excludes_when: str | None = None
    # Evidence fields (belief-model fixtures). When `belief` is set, seed-memories computes the stored
    # confidence as belief × freshness × outcome factors; omit for a plain age-only seed.
    belief: float | None = None
    times_sighted: int | None = None
    times_applied_success: int | None = None
    times_overridden: int | None = None
    age_days: int | None = None

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> "MemorySpec":
        def _i(key: str) -> int | None:
            return int(raw[key]) if raw.get(key) is not None else None
        return MemorySpec(
            type=raw["type"],
            title=raw["title"],
            summary=raw["summary"],
            confidence=float(raw.get("confidence", 1.0)),
            status=raw.get("status", "confirmed"),
            applies_when=raw.get("appliesWhen"),
            excludes_when=raw.get("excludesWhen"),
            belief=float(raw["belief"]) if raw.get("belief") is not None else None,
            times_sighted=_i("timesSighted"),
            times_applied_success=_i("timesAppliedSuccess"),
            times_overridden=_i("timesOverridden"),
            age_days=_i("ageDays"),
        )

    def to_seed_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "type": self.type,
            "title": self.title,
            "summary": self.summary,
            "confidence": self.confidence,
            "status": self.status,
        }
        if self.applies_when is not None:
            d["appliesWhen"] = self.applies_when
        if self.excludes_when is not None:
            d["excludesWhen"] = self.excludes_when
        for key, val in (("belief", self.belief), ("timesSighted", self.times_sighted),
                         ("timesAppliedSuccess", self.times_applied_success),
                         ("timesOverridden", self.times_overridden), ("ageDays", self.age_days)):
            if val is not None:
                d[key] = val
        return d


@dataclass(slots=True)
class Requirement:
    """One independently-checkable sub-requirement, for partial-credit completeness scoring."""

    id: str
    description: str
    command: str

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> "Requirement":
        return Requirement(id=raw["id"], description=raw["description"], command=raw["command"])


@dataclass(slots=True)
class TaskSpec:
    id: str
    name: str
    suite: str
    family: str
    prompt: str
    seed_scenario: str
    overlays: list[str]            # agent-visible files copied in BEFORE the run
    grader_overlays: list[str]     # held-out files (e.g. acceptance tests) copied in AFTER the run
    memory_seed: list[MemorySpec]  # memories loaded into the isolated store (memory/oracle conditions)
    warmup: list[str]              # warmup prompts whose sessions are replayed into memory (earned_hooks)
    requirements: list[Requirement]
    timeout_seconds: int
    max_budget_usd: float
    graders: dict[str, list[str]]
    difficulty: str = "medium"
    tags: list[str] = field(default_factory=list)

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> "TaskSpec":
        return TaskSpec(
            id=raw["id"],
            name=raw["name"],
            suite=raw["suite"],
            family=raw["family"],
            prompt=raw["prompt"],
            seed_scenario=raw["seed_scenario"],
            overlays=list(raw.get("overlays", [])),
            grader_overlays=list(raw.get("grader_overlays", [])),
            memory_seed=[MemorySpec.from_dict(m) for m in raw.get("memory_seed", [])],
            warmup=list(raw.get("warmup", [])),
            requirements=[Requirement.from_dict(r) for r in raw.get("requirements", [])],
            timeout_seconds=int(raw["timeout_seconds"]),
            max_budget_usd=float(raw["max_budget_usd"]),
            graders=dict(raw["graders"]),
            difficulty=raw.get("difficulty", "medium"),
            tags=list(raw.get("tags", [])),
        )


@dataclass(slots=True)
class TrialArtifacts:
    workspace: Path
    stdout_path: Path
    stream_json_path: Path
    diff_path: Path
    grader_log_path: Path
    injected_context_path: Path
