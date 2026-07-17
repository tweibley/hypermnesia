"""Shared pagination helper. Reuse this for any list endpoint instead of re-implementing slicing."""
from __future__ import annotations

from typing import TypeVar

T = TypeVar("T")


def paginate(items: list[T], *, limit: int = 50, offset: int = 0) -> list[T]:
    """Return a window of `items` starting at `offset`, at most `limit` long.

    Clamps negative inputs to zero so callers don't have to validate.
    """
    limit = max(limit, 0)
    offset = max(offset, 0)
    return items[offset : offset + limit]
