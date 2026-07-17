from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from jsonschema import validate

from .models import TaskSpec


def _read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def load_task_spec(task_path: Path, schema_path: Path) -> TaskSpec:
    raw = _read_json(task_path)
    schema = _read_json(schema_path)
    validate(instance=raw, schema=schema)
    return TaskSpec.from_dict(raw)


def load_task_specs(task_paths: list[Path], schema_path: Path) -> list[TaskSpec]:
    return [load_task_spec(path, schema_path) for path in task_paths]

