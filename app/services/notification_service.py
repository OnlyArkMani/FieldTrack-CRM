"""Notification orchestration: in-app rows (source of truth) + best-effort FCM.

CONTRACT (mirrors FCMService):
- The `notifications` row is AUTHORITATIVE. It is written and flushed BEFORE we
  attempt a push; if the push fails (dead project, expired token, no network)
  the user still sees the item in-app. Push is only the nudge.
- Push failures NEVER raise. A stale token (UNREGISTERED) is reaped (nulled in
  device_info) so we stop targeting a dead device; the app re-registers a fresh
  token on next open (see fcm_service.dart).
- Transaction ownership: these methods own their unit of work and commit by
  default (scheduler jobs, the announcement endpoint, and device-reported
  events each call one method and are done). Inline callers that want the
  notification to ride THEIR transaction pass commit=False.

BULK: send_bulk_fcm chunks tokens at FCM's 500-per-request ceiling. (HTTP v1
dropped true multicast; at 15-100 employees a fan-out is a handful of devices,
so a sequential per-token send inside each chunk — see FCMService — is simplest
and has isolated per-token failures.)
"""
import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.misc import Notification
from app.models.user import Team, User
from app.repositories.notification_repository import NotificationRepository
from app.schemas.notification import NotificationType
from app.services.fcm_service import FCMService

logger = logging.getLogger("fieldtrack.notifications")

FCM_BATCH_SIZE = 500


class NotificationService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = NotificationRepository(db)
        self.fcm = FCMService()

    # ── Core: one user ───────────────────────────────────────────────────
    async def send_fcm(
        self,
        user_id: int,
        *,
        title: str,
        body: str,
        type: str | NotificationType = NotificationType.ADMIN_ANNOUNCEMENT,
        data: dict[str, str] | None = None,
        commit: bool = True,
    ) -> Notification:
        """Persist an in-app notification for `user_id` and push it best-effort.

        Returns the created row (so callers can echo its id). The push's first
        delivered message id is stored on the row for traceability."""
        type_str = _type_str(type)
        notif = self.repo.add(
            Notification(user_id=user_id, title=title, body=body, type=type_str)
        )
        await self.db.flush()

        tokens = await self.repo.tokens_for_user(user_id)
        if tokens:
            result = await self.fcm.send_and_classify(
                tokens, title=title, body=body, data=_payload(type_str, data)
            )
            if result.delivered:
                notif.fcm_message_id = result.delivered[0]
            for dead in result.stale_tokens:
                await self.repo.mark_token_stale(dead)

        if commit:
            await self.db.commit()
        return notif

    # ── Core: many users (announcements / scheduled fan-outs) ────────────
    async def send_bulk_fcm(
        self,
        user_ids: list[int],
        *,
        title: str,
        body: str,
        type: str | NotificationType = NotificationType.ADMIN_ANNOUNCEMENT,
        data: dict[str, str] | None = None,
        commit: bool = True,
    ) -> tuple[int, int]:
        """Persist one in-app row per user and fan a push out to all their
        devices. Returns (recipients, pushed) — rows created and devices a push
        was delivered to."""
        recipients = list(dict.fromkeys(user_ids))  # de-dupe, preserve order
        if not recipients:
            return (0, 0)

        type_str = _type_str(type)
        for uid in recipients:
            self.repo.add(
                Notification(user_id=uid, title=title, body=body, type=type_str)
            )
        await self.db.flush()

        pushed = 0
        tokens = await self.repo.tokens_for_users(recipients)
        payload = _payload(type_str, data)
        for start in range(0, len(tokens), FCM_BATCH_SIZE):
            chunk = tokens[start : start + FCM_BATCH_SIZE]
            result = await self.fcm.send_and_classify(
                chunk, title=title, body=body, data=payload
            )
            pushed += result.delivered_count
            for dead in result.stale_tokens:
                await self.repo.mark_token_stale(dead)

        if commit:
            await self.db.commit()
        return (len(recipients), pushed)

    # ── Typed triggers ───────────────────────────────────────────────────
    async def attendance_reminder(self, user_id: int, *, commit: bool = False) -> Notification:
        """9AM nudge to the employee who hasn't started their day."""
        return await self.send_fcm(
            user_id,
            title="Start your day",
            body="You haven't marked attendance yet. Tap to clock in.",
            type=NotificationType.ATTENDANCE_REMINDER,
            data={"screen": "attendance"},
            commit=commit,
        )

    async def end_work_reminder(self, user_id: int, *, commit: bool = False) -> Notification:
        """6PM nudge to the employee still on the clock."""
        return await self.send_fcm(
            user_id,
            title="Wrap up your day",
            body="You're still clocked in. Don't forget to end attendance.",
            type=NotificationType.END_WORK_REMINDER,
            data={"screen": "attendance"},
            commit=commit,
        )

    async def gps_disabled(self, employee_id: int, *, commit: bool = True) -> Notification | None:
        """The employee's device reported GPS turned off. Notify their
        supervisor (anti-gaming visibility), not the employee. Returns the
        supervisor's notification, or None if no supervisor is set."""
        employee = await self.db.get(User, employee_id)
        if employee is None:
            return None
        supervisor_id = await self._supervisor_for(employee)
        if supervisor_id is None:
            return None
        return await self.send_fcm(
            supervisor_id,
            title="GPS turned off",
            body=f"{employee.name} disabled location. Tracking is paused.",
            type=NotificationType.GPS_DISABLED,
            data={"screen": "employee", "employee_id": str(employee_id)},
            commit=commit,
        )

    async def absentee_alert(
        self, supervisor_id: int, *, absent_names: list[str], commit: bool = False
    ) -> Notification:
        """09:30 alert to a supervisor: which of their executives haven't clocked
        in. One aggregate notification per team (mirrors the late-DSR fan-out)."""
        n = len(absent_names)
        preview = ", ".join(absent_names[:3])
        if n > 3:
            preview += f" +{n - 3} more"
        body = (
            f"{n} team member(s) not checked in by 09:30: {preview}."
            if preview
            else f"{n} team member(s) not checked in by 09:30."
        )
        return await self.send_fcm(
            supervisor_id,
            title="Attendance alert",
            body=body,
            type=NotificationType.ABSENTEE_ALERT,
            data={"screen": "attendance"},
            commit=commit,
        )

    async def stationary_alert(
        self,
        supervisor_id: int,
        *,
        employee_id: int,
        employee_name: str,
        minutes: int,
        commit: bool = False,
    ) -> Notification:
        """Alert a supervisor that an on-clock executive hasn't moved for
        `minutes` during field hours (anti-idling visibility)."""
        return await self.send_fcm(
            supervisor_id,
            title="Executive stationary",
            body=f"{employee_name} hasn't moved for {minutes}+ min during field hours.",
            type=NotificationType.STATIONARY_ALERT,
            data={"screen": "employee", "employee_id": str(employee_id)},
            commit=commit,
        )

    async def report_ready(
        self,
        user_id: int,
        *,
        weekly: bool,
        period_label: str,
        download_url: str,
        commit: bool = False,
    ) -> Notification:
        """Notify a supervisor that an auto-generated weekly/monthly team report
        is ready to download."""
        kind = "Weekly" if weekly else "Monthly"
        return await self.send_fcm(
            user_id,
            title=f"{kind} report ready",
            body=f"Your {kind.lower()} team report for {period_label} is ready to download.",
            type=NotificationType.WEEKLY_REPORT if weekly else NotificationType.MONTHLY_REPORT,
            data={"screen": "reports", "download_url": download_url},
            commit=commit,
        )

    async def sync_failed(self, user_id: int, *, commit: bool = True) -> Notification:
        """After 3 consecutive sync failures (called by the sync layer)."""
        return await self.send_fcm(
            user_id,
            title="Sync trouble",
            body="We're having trouble uploading your data. We'll keep retrying.",
            type=NotificationType.SYNC_FAILED,
            data={"screen": "dashboard"},
            commit=commit,
        )

    # ── Admin announcement ───────────────────────────────────────────────
    async def announce(
        self, *, title: str, body: str, team_id: int | None
    ) -> tuple[int, int]:
        """Admin broadcast. team_id resolves to that team's active members;
        null broadcasts to every active field user. Returns (recipients,
        pushed)."""
        if team_id is not None:
            recipients = await self.repo.active_team_member_ids(team_id)
        else:
            recipients = await self.repo.active_field_user_ids()
        return await self.send_bulk_fcm(
            recipients,
            title=title,
            body=body,
            type=NotificationType.ADMIN_ANNOUNCEMENT,
            data={"screen": "notifications"},
            commit=True,
        )

    # ── Device token registration (mobile) ───────────────────────────────
    async def register_device(
        self,
        user: User,
        *,
        fcm_token: str,
        device_model: str | None = None,
        os_version: str | None = None,
        app_version: str | None = None,
    ):
        """Upsert this device by its FCM token and bind it to `user`.

        - Token already known: re-bind to this user (re-login on the same
          handset) and refresh metadata + last_seen.
        - New token: create a row.
        Then null this user's OTHER tokens — FieldTrack is one-device-per-user
        (mirrors the single-session refresh-token rule); a fresh registration
        means the previous device is no longer the live target."""
        from datetime import datetime, timezone

        from app.models.misc import DeviceInfo

        now = datetime.now(timezone.utc)
        device = await self.repo.get_device_by_token(fcm_token)
        if device is None:
            device = self.repo.add_device(
                DeviceInfo(user_id=user.id, fcm_token=fcm_token)
            )
        device.user_id = user.id
        device.fcm_token = fcm_token
        if device_model is not None:
            device.device_model = device_model
        if os_version is not None:
            device.os_version = os_version
        if app_version is not None:
            device.app_version = app_version
        device.last_seen = now
        await self.db.flush()

        # Reap the user's stale tokens (any token other than the one just
        # registered) so we never push to a retired handset.
        from sqlalchemy import update as sa_update

        await self.db.execute(
            sa_update(DeviceInfo)
            .where(
                DeviceInfo.user_id == user.id,
                DeviceInfo.fcm_token.is_not(None),
                DeviceInfo.fcm_token != fcm_token,
            )
            .values(fcm_token=None)
        )
        await self.db.commit()
        await self.db.refresh(device)
        return device

    # ── Helpers ──────────────────────────────────────────────────────────
    async def _supervisor_for(self, employee: User) -> int | None:
        """Resolve the supervisor a notification about this employee should go
        to: the supervisor of the employee's team (never the employee
        themselves)."""
        if employee.team_id is None:
            return None
        supervisor_id = (
            await self.db.execute(
                select(Team.supervisor_id).where(Team.id == employee.team_id)
            )
        ).scalar_one_or_none()
        if supervisor_id is None or supervisor_id == employee.id:
            return None
        return int(supervisor_id)


# ── Module helpers ────────────────────────────────────────────────────────
def _type_str(type: str | NotificationType) -> str:
    return type.value if isinstance(type, NotificationType) else type


def _payload(type_str: str, data: dict[str, str] | None) -> dict[str, str]:
    """Build the FCM data payload. `type` is always present so the mobile
    onMessageOpenedApp switch and the in-app tap handler share one routing
    key. FCM requires all data values to be strings."""
    payload: dict[str, str] = {"type": type_str}
    if data:
        payload.update({k: str(v) for k, v in data.items()})
    return payload
