"""Persistent storage for ledger entries.

Data file layout::

    {
      "entries": [{"id": 1, "text": "...", "created_at": "..."}],
      "meta": {}
    }
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


Entry = dict[str, Any]
_STORE_VERSION = 1


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def load(data_file: Path) -> dict[str, Any]:
    """Load the data file, returning a fresh empty store if the file does not exist."""
    if not data_file.exists():
        return {"version": _STORE_VERSION, "entries": [], "meta": {}}
    with data_file.open(encoding="utf-8") as fh:
        return json.load(fh)  # type: ignore[no-any-return]


def save(data_file: Path, store: dict[str, Any]) -> None:
    """Persist the store to disk (atomic-ish: write then replace via Path.write_text)."""
    data_file.parent.mkdir(parents=True, exist_ok=True)
    data_file.write_text(json.dumps(store, indent=2), encoding="utf-8")


def add_entry(data_file: Path, text: str) -> Entry:
    """Append a new entry and return it."""
    store = load(data_file)
    entries: list[Entry] = store["entries"]
    existing_ids = [e["id"] for e in entries]
    # id = max(existing ids) + 1
    new_id = max(existing_ids) + 1 if existing_ids else 1
    entry: Entry = {"id": new_id, "text": text, "created_at": _now_iso()}
    entries.append(entry)
    save(data_file, store)
    return entry


def list_entries(data_file: Path) -> list[Entry]:
    """Return all entries, ordered by id ascending."""
    store = load(data_file)
    entries: list[Entry] = store["entries"]
    return sorted(entries, key=lambda e: e["id"])
