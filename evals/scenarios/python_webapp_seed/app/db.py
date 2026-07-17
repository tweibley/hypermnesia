from __future__ import annotations

from datetime import datetime, timezone

from .models import Task, User


USERS = {
    1: User(id=1, email="admin@example.com", role="admin"),
    2: User(id=2, email="member@example.com", role="member"),
    3: User(id=3, email="viewer@example.com", role="viewer"),
}

TASKS: dict[int, Task] = {
    1: Task(id=1, title="Bootstrap API", status="in_progress", owner_id=2),
    2: Task(id=2, title="Wire CI", status="todo", owner_id=2),
}


def list_tasks() -> list[Task]:
    return [TASKS[key] for key in sorted(TASKS.keys())]


def get_task(task_id: int) -> Task | None:
    return TASKS.get(task_id)


def create_task(title: str, owner_id: int) -> Task:
    next_id = max(TASKS.keys(), default=0) + 1
    task = Task(id=next_id, title=title, owner_id=owner_id, status="todo")
    TASKS[next_id] = task
    return task


def update_task(task_id: int, *, title: str | None = None, status: str | None = None) -> Task | None:
    task = TASKS.get(task_id)
    if not task:
        return None
    payload = task.model_dump()
    if title is not None:
        payload["title"] = title
    if status is not None:
        payload["status"] = status
    payload["updated_at"] = datetime.now(timezone.utc)
    next_task = Task(**payload)
    TASKS[task_id] = next_task
    return next_task

