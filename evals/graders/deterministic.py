from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from evals.runner.models import Requirement


@dataclass(slots=True)
class CommandResult:
    command: str
    exit_code: int
    stdout: str
    stderr: str
    label: str = ""

    @property
    def passed(self) -> bool:
        return self.exit_code == 0

    def to_dict(self) -> dict:
        return {
            "command": self.command,
            "label": self.label,
            "exit_code": self.exit_code,
            "passed": self.passed,
            "stdout": self.stdout[-4000:],
            "stderr": self.stderr[-4000:],
        }


@dataclass(slots=True)
class DeterministicGrade:
    outcome: list[CommandResult]
    regression: list[CommandResult]
    static: list[CommandResult]
    requirements: list[CommandResult] = field(default_factory=list)

    @property
    def outcome_pass(self) -> bool:
        return bool(self.outcome) and all(r.passed for r in self.outcome)

    @property
    def regression_pass(self) -> bool:
        return all(r.passed for r in self.regression)

    @property
    def static_pass(self) -> bool:
        return all(r.passed for r in self.static)

    @property
    def completeness(self) -> float:
        """Fraction of independently-checkable sub-requirements satisfied (partial credit)."""
        if not self.requirements:
            return 1.0 if self.outcome_pass else 0.0
        return sum(1 for r in self.requirements if r.passed) / len(self.requirements)

    def to_dict(self) -> dict:
        return {
            "outcome": [r.to_dict() for r in self.outcome],
            "regression": [r.to_dict() for r in self.regression],
            "static": [r.to_dict() for r in self.static],
            "requirements": [r.to_dict() for r in self.requirements],
            "completeness": round(self.completeness, 4),
        }


def run_command(command: str, cwd: Path, env: dict[str, str] | None = None, label: str = "") -> CommandResult:
    proc = subprocess.run(command, cwd=cwd, shell=True, capture_output=True, text=True, env=env)
    return CommandResult(
        command=command, exit_code=proc.returncode, stdout=proc.stdout, stderr=proc.stderr, label=label
    )


def grade_deterministic(
    graders: dict[str, list[str]],
    requirements: list[Requirement],
    workspace: Path,
    env: dict[str, str] | None = None,
) -> DeterministicGrade:
    outcome = [run_command(c, workspace, env) for c in graders.get("outcome", [])]
    regression = [run_command(c, workspace, env) for c in graders.get("regression", [])]
    static = [run_command(c, workspace, env) for c in graders.get("static", [])]
    reqs = [run_command(r.command, workspace, env, label=f"{r.id}: {r.description}") for r in requirements]
    return DeterministicGrade(outcome=outcome, regression=regression, static=static, requirements=reqs)


def write_grade_log(grade: DeterministicGrade, path: Path) -> None:
    path.write_text(json.dumps(grade.to_dict(), indent=2), encoding="utf-8")
