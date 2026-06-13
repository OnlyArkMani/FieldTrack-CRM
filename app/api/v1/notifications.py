"""Notifications router — thin HTTP layer; logic in NotificationService /
NotificationRepository.

AUTHZ:
- list / unread-count / mark-read / read-all: the current user's own inbox
  only (rows are filtered by user_id at the repo layer — no cross-user reads).
- announcement: ADMIN only (per role matrix; admins are the only announcers).
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_current_admin, get_db
from app.models.user import User
from app.repositories.notification_repository import NotificationRepository
from app.schemas.common import CursorPage, decode_cursor, encode_cursor
from app.schemas.notification import (
    AnnouncementIn,
    AnnouncementResult,
    MarkReadResult,
    NotificationOut,
    UnreadCountOut,
)
from app.services.notification_service import NotificationService

router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("", response_model=CursorPage[NotificationOut])
async def list_notifications(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    cursor: str | None = Query(default=None, description="Opaque forward cursor"),
    limit: int = Query(default=20, ge=1, le=100),
) -> CursorPage[NotificationOut]:
    """Current user's notifications, newest first."""
    repo = NotificationRepository(db)
    rows, total = await repo.list_for_user(
        user.id, cursor_id=decode_cursor(cursor), limit=limit
    )
    has_more = len(rows) > limit
    page = rows[:limit]
    next_cursor = encode_cursor(page[-1].id) if has_more and page else None
    return CursorPage[NotificationOut](
        items=[NotificationOut.model_validate(r) for r in page],
        next_cursor=next_cursor,
        total=total,
        has_more=has_more,
    )


@router.get("/unread-count", response_model=UnreadCountOut)
async def unread_count(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> UnreadCountOut:
    """Badge count for the app-icon / bell. Cheap COUNT on a covering index."""
    repo = NotificationRepository(db)
    return UnreadCountOut(unread=await repo.unread_count(user.id))


@router.patch("/read-all", response_model=MarkReadResult)
async def mark_all_read(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MarkReadResult:
    """Clear the whole inbox's unread state in one statement.

    NOTE: declared before /{notification_id}/read so 'read-all' is never
    swallowed by the int path param."""
    repo = NotificationRepository(db)
    updated = await repo.mark_all_read(user.id)
    await db.commit()
    return MarkReadResult(updated=updated, unread=0)


@router.patch("/{notification_id}/read", response_model=MarkReadResult)
async def mark_read(
    notification_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MarkReadResult:
    """Mark one notification read. Idempotent: a not-yours / already-read id
    returns updated=0 (never 404 — the client's optimistic UI shouldn't error
    on a double-tap)."""
    repo = NotificationRepository(db)
    updated = await repo.mark_read(user.id, notification_id)
    await db.commit()
    return MarkReadResult(updated=updated, unread=await repo.unread_count(user.id))


@router.post("/announcement", response_model=AnnouncementResult, status_code=201)
async def send_announcement(
    body: AnnouncementIn,
    _admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AnnouncementResult:
    """Admin → a team (team_id) or all field users (team_id null). Creates one
    in-app notification per recipient and pushes best-effort."""
    recipients, pushed = await NotificationService(db).announce(
        title=body.title, body=body.body, team_id=body.team_id
    )
    return AnnouncementResult(recipients=recipients, pushed=pushed)
