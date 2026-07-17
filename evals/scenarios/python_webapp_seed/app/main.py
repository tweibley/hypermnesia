from __future__ import annotations

from fastapi import FastAPI, HTTPException

from . import db
from .models import CreateTaskRequest, Task, UpdateTaskRequest, User


app = FastAPI(title="Synthetic Eval API")


def get_user(user_id: int) -> User:
    user = db.USERS.get(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="user not found")
    return user


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/users")
def list_users() -> list[User]:
    return [db.USERS[key] for key in sorted(db.USERS.keys())]


@app.get("/tasks")
def list_tasks() -> list[Task]:
    return db.list_tasks()


@app.post("/tasks", status_code=201)
def create_task(request: CreateTaskRequest) -> Task:
    if request.owner_id not in db.USERS:
        raise HTTPException(status_code=422, detail="invalid owner")
    return db.create_task(title=request.title, owner_id=request.owner_id)


@app.patch("/tasks/{task_id}")
def patch_task(task_id: int, request: UpdateTaskRequest, actor_id: int) -> Task:
    actor = get_user(actor_id)
    existing = db.get_task(task_id)
    if not existing:
        raise HTTPException(status_code=404, detail="task not found")

    if actor.role == "viewer":
        raise HTTPException(status_code=403, detail="viewer cannot modify tasks")
    if actor.role == "member" and existing.owner_id != actor.id:
        raise HTTPException(status_code=403, detail="member can edit only owned tasks")
    updated = db.update_task(task_id, title=request.title, status=request.status)
    assert updated is not None  # the task exists (checked above), so update_task returns it
    return updated

