from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal

from pydantic import BaseModel, Field


Role = Literal["admin", "member", "viewer"]
TaskStatus = Literal["todo", "in_progress", "done"]


class User(BaseModel):
    id: int
    email: str
    role: Role


class Task(BaseModel):
    id: int
    title: str = Field(min_length=3)
    status: TaskStatus = "todo"
    owner_id: int
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class CreateTaskRequest(BaseModel):
    title: str = Field(min_length=3)
    owner_id: int


class UpdateTaskRequest(BaseModel):
    title: str | None = None
    status: TaskStatus | None = None

