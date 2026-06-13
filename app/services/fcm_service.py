"""Firebase Cloud Messaging (HTTP v1) sender — best-effort, never blocking.

DECISIONS:
- HTTP v1 (not the legacy server-key API): legacy is deprecated. Auth is an
  OAuth2 bearer minted from the service-account JSON via google-auth.
- BEST-EFFORT BY CONTRACT: push is a side effect, never the point of a
  request. Every public method swallows its own errors and logs — a dead FCM
  project, an expired token, or no network must NOT 500 a create/update.
  Callers therefore never await this inside their DB transaction's critical
  path and never branch on its result for correctness.
- DEV/UNCONFIGURED ⇒ no-op + log. If fcm_service_account_file is unset the
  app still runs end-to-end locally; we just don't hit Google. This mirrors
  the auth OTP "dev logs, prod must be wired" stance but is softer because a
  missing push is non-fatal (the in-app Notification row is the source of
  truth; push is only the nudge).
- The OAuth access token is cached until ~60 s before expiry — minting one per
  send would add latency and rate pressure.
"""
import json
import logging
import time
from typing import Any

import httpx

from app.core.config import get_settings

logger = logging.getLogger("fieldtrack.fcm")

_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"


class FCMService:
    # Class-level token cache shared across instances (one project, one creds).
    _access_token: str | None = None
    _token_exp: float = 0.0

    def __init__(self) -> None:
        self.settings = get_settings()

    @property
    def _configured(self) -> bool:
        return bool(
            self.settings.fcm_service_account_file
            and self.settings.fcm_project_id
        )

    async def _bearer(self) -> str | None:
        """Mint/return a cached OAuth2 access token for the service account.

        google-auth's refresh is synchronous; it's called at most once per
        ~hour so the brief block is acceptable and far simpler than a custom
        async JWT-grant flow.
        """
        now = time.time()
        if FCMService._access_token and now < FCMService._token_exp - 60:
            return FCMService._access_token
        try:
            from google.auth.transport.requests import Request
            from google.oauth2 import service_account

            creds = service_account.Credentials.from_service_account_file(
                self.settings.fcm_service_account_file, scopes=[_SCOPE]
            )
            creds.refresh(Request())
            FCMService._access_token = creds.token
            # creds.expiry is naive UTC; convert to epoch for comparison.
            FCMService._token_exp = creds.expiry.timestamp() if creds.expiry else now + 3000
            return FCMService._access_token
        except Exception:  # noqa: BLE001 — best-effort; never propagate
            logger.exception("FCM: failed to obtain access token")
            return None

    async def send_to_tokens(
        self,
        tokens: list[str],
        *,
        title: str,
        body: str,
        data: dict[str, str] | None = None,
    ) -> list[str]:
        """Send one notification to each token. Returns delivered message ids.

        Sends sequentially: at 15–100 employees a welcome/announcement fans
        out to a handful of devices — a worker pool buys nothing and adds
        failure modes. Per-token failures are isolated (one bad token never
        sinks the batch).
        """
        if not tokens:
            return []
        if not self._configured:
            logger.info(
                "FCM not configured (dev) — would send '%s' to %d device(s)",
                title,
                len(tokens),
            )
            return []

        bearer = await self._bearer()
        if bearer is None:
            return []

        url = (
            f"https://fcm.googleapis.com/v1/projects/"
            f"{self.settings.fcm_project_id}/messages:send"
        )
        headers = {
            "Authorization": f"Bearer {bearer}",
            "Content-Type": "application/json",
        }
        delivered: list[str] = []
        async with httpx.AsyncClient(timeout=10.0) as client:
            for token in tokens:
                message: dict[str, Any] = {
                    "message": {
                        "token": token,
                        "notification": {"title": title, "body": body},
                    }
                }
                if data:
                    message["message"]["data"] = data
                try:
                    resp = await client.post(url, headers=headers, content=json.dumps(message))
                    if resp.status_code == 200:
                        delivered.append(resp.json().get("name", ""))
                    else:
                        logger.warning(
                            "FCM send failed (%s): %s", resp.status_code, resp.text[:200]
                        )
                except Exception:  # noqa: BLE001
                    logger.exception("FCM: send error for one token")
        return delivered

    async def send_and_classify(
        self,
        tokens: list[str],
        *,
        title: str,
        body: str,
        data: dict[str, str] | None = None,
    ) -> "FcmResult":
        """Like send_to_tokens but reports which tokens are DEAD so the caller
        can null them in device_info (stale-token reaping).

        FCM HTTP v1 signals a permanently-invalid token with HTTP 404 +
        error.status == 'UNREGISTERED', or HTTP 400 + 'INVALID_ARGUMENT' for a
        malformed token. Those are the only statuses we treat as "stop sending
        to this token"; transient 5xx/timeouts are NOT stale (the device is
        fine, the push just didn't land this cycle).
        """
        result = FcmResult()
        if not tokens:
            return result
        if not self._configured:
            logger.info(
                "FCM not configured (dev) — would send '%s' to %d device(s)",
                title,
                len(tokens),
            )
            return result

        bearer = await self._bearer()
        if bearer is None:
            return result

        url = (
            f"https://fcm.googleapis.com/v1/projects/"
            f"{self.settings.fcm_project_id}/messages:send"
        )
        headers = {
            "Authorization": f"Bearer {bearer}",
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(timeout=10.0) as client:
            for token in tokens:
                message: dict[str, Any] = {
                    "message": {
                        "token": token,
                        "notification": {"title": title, "body": body},
                    }
                }
                if data:
                    message["message"]["data"] = data
                try:
                    resp = await client.post(
                        url, headers=headers, content=json.dumps(message)
                    )
                    if resp.status_code == 200:
                        result.delivered.append(resp.json().get("name", ""))
                    elif self._is_stale_token(resp):
                        logger.info("FCM token unregistered — reaping")
                        result.stale_tokens.append(token)
                    else:
                        logger.warning(
                            "FCM send failed (%s): %s",
                            resp.status_code,
                            resp.text[:200],
                        )
                        result.failed += 1
                except Exception:  # noqa: BLE001
                    logger.exception("FCM: send error for one token")
                    result.failed += 1
        return result

    @staticmethod
    def _is_stale_token(resp: httpx.Response) -> bool:
        if resp.status_code not in (400, 404):
            return False
        try:
            status = resp.json().get("error", {}).get("status", "")
        except Exception:  # noqa: BLE001
            return resp.status_code == 404
        return status in ("UNREGISTERED", "INVALID_ARGUMENT", "NOT_FOUND")


class FcmResult:
    """Outcome of a fan-out send. `stale_tokens` are caller-owned cleanup."""

    __slots__ = ("delivered", "stale_tokens", "failed")

    def __init__(self) -> None:
        self.delivered: list[str] = []
        self.stale_tokens: list[str] = []
        self.failed: int = 0

    @property
    def delivered_count(self) -> int:
        return len(self.delivered)
