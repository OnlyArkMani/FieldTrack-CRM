"""Devices router — FCM token registration and device-reported events.

The mobile app registers its FCM token here on first launch and on every token
rotation (FCM rotates periodically). It also reports when the user turns GPS
off so a supervisor can be alerted (anti-gaming visibility).

AUTHZ: any authenticated active user — these are device-scoped, self-only
actions (the token is bound to the caller; the GPS event is about the caller).
"""
from typing import Annotated

from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_db
from app.schemas.notification import DeviceTokenIn, DeviceTokenOut
from app.services.notification_service import NotificationService

router = APIRouter(prefix="/devices", tags=["devices"])


@router.post("/token", response_model=DeviceTokenOut, status_code=status.HTTP_201_CREATED)
async def register_token(
    body: DeviceTokenIn,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> DeviceTokenOut:
    """Upsert this handset's FCM token and bind it to the caller. Idempotent:
    re-posting the same token just refreshes metadata + last_seen."""
    device = await NotificationService(db).register_device(
        user,
        fcm_token=body.fcm_token,
        device_model=body.device_model,
        os_version=body.os_version,
        app_version=body.app_version,
    )
    return DeviceTokenOut.model_validate(device)


@router.post("/gps-disabled", status_code=status.HTTP_202_ACCEPTED)
async def report_gps_disabled(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """The caller's device detected location services are off. Best-effort:
    notifies the caller's supervisor. Always 202 (fire-and-forget from the
    device's perspective; the employee gets no signal they were flagged)."""
    await NotificationService(db).gps_disabled(user.id)
    return {"status": "accepted"}
