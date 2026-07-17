from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Any


# The judge runs on the strongest model (Opus 4.8) while subjects run on a cheaper model — the
# standard eval split. It scores subjective quality the deterministic graders can't: did the change
# adhere to the instructions, stay minimal, and read as maintainable code?
JUDGE_MODEL = "claude-opus-4-8"

RUBRIC_TEMPLATE = """You are grading the output of a coding agent. Score each dimension from 1 (poor) to 5 (excellent):
- instruction_adherence: did the diff do what the task asked, and only that?
- minimality: is the change focused, with no gratuitous edits or dead code?
- maintainability: is the code clear, consistent with the surrounding style, and correct?

Respond with ONLY a JSON object, no prose:
{{"instruction_adherence": <int>, "minimality": <int>, "maintainability": <int>, "notes": "<one sentence>"}}

## Task
{task_prompt}

## Diff
{diff_text}
"""


def _extract_json(text: str) -> dict[str, Any] | None:
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if fenced:
        try:
            return json.loads(fenced.group(1))
        except json.JSONDecodeError:
            pass
    start = text.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start : i + 1])
                    except json.JSONDecodeError:
                        break
        start = text.find("{", start + 1)
    return None


def maybe_grade_with_rubric(
    *,
    enabled: bool,
    task_prompt: str,
    diff_path: Path,
    output_path: Path,
    judge_model: str = JUDGE_MODEL,
    judge_effort: str = "high",
    claude_bin: str = "claude",
    timeout_seconds: int = 180,
) -> float:
    if not enabled:
        output_path.write_text(
            json.dumps({"enabled": False, "rubric_score": 0.0, "notes": "rubric disabled"}, indent=2),
            encoding="utf-8",
        )
        return 0.0

    diff_text = diff_path.read_text(encoding="utf-8")
    if not diff_text.strip():
        output_path.write_text(
            json.dumps({"enabled": True, "rubric_score": 0.0, "notes": "empty diff"}, indent=2),
            encoding="utf-8",
        )
        return 0.0

    prompt = RUBRIC_TEMPLATE.format(task_prompt=task_prompt, diff_text=diff_text[:12000])
    # Plain --print text output; we parse JSON ourselves. (--json-schema returns empty and --bare
    # breaks subscription auth — see project notes on headless gotchas.) Always bound with a timeout.
    try:
        proc = subprocess.run(
            [claude_bin, "--print", "--model", judge_model, "--effort", judge_effort, prompt],
            capture_output=True, text=True, timeout=timeout_seconds,
        )
        parsed = _extract_json(proc.stdout) or {}
    except (subprocess.TimeoutExpired, OSError) as exc:
        output_path.write_text(
            json.dumps({"enabled": True, "rubric_score": 0.0, "error": str(exc)}, indent=2),
            encoding="utf-8",
        )
        return 0.0

    dims = ["instruction_adherence", "minimality", "maintainability"]
    scores = [float(parsed.get(d, 0) or 0) for d in dims]
    rubric_score = round(sum(scores) / len(scores), 3) if any(scores) else 0.0
    output_path.write_text(
        json.dumps(
            {
                "enabled": True,
                "judge_model": judge_model,
                "rubric_score": rubric_score,
                "dimensions": {d: parsed.get(d) for d in dims},
                "notes": parsed.get("notes", ""),
                "raw": proc.stdout[-2000:],
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    return rubric_score
