"""Auth business logic. Routers stay thin; this layer owns transactions.

SECURITY DECISIONS (explicit):
- Login: identical error for unknown email vs wrong password
  (INVALID_CREDENTIALS) — no account enumeration. A dummy bcrypt verify runs
  even when the email is unknown so response timing doesn't leak existence.
- One active refresh session per user: Redis stores sha256(refresh_token) at
  fieldtrack:refresh:{user_id}. New login overwrites it => old device's
  refresh dies. Deliberate for an attendance product (one identity, one device).
- Rotation + reuse detection: /refresh validates the JWT AND compares its
  sha256 to the stored fingerprint. Valid-JWT-but-wrong-fingerprint means an
  OLD (rotated-out) token is being replayed — possible theft — so the session
  is revoked entirely and the event is audited.
- Old refresh jti is blacklisted immediately on rotation (TTL = its remaining
  lifetime), belt-and-braces on top of the fingerprint swap.
- Password reset revokes the refresh session. Outstanding access tokens live
  at most 15 more minutes — accepted tradeoff (tracking per-user token
  versions would add a DB read per request).
- OTP: 6 digits, sha256-hashed in Redis, 10 min TTL, max 5 verify attempts
  (counter lives in the same hash — attempts can't outlive the OTP).
  Forgot-password always returns 200 (no enumeration). Dev mode logs the OTP;
  prod delivery (FCM/email) is a TODO hook, not a silent no-op — it raises in
  prod until wired so you can't ship a dead reset flow.
"""
import logging
import secrets
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import (
    ApiError,
    invalid_credentials,
    invalid_otp,
    token_invalid,
    user_inactive,
)
from app.core.redis import Keys, get_redis
from app.core.security import (
    blacklist_token,
    create_access_token,
    create_refresh_token,
    hash_password,
    remaining_ttl_seconds,
    sha256_hex,
    verify_password,
    verify_token,
)
from app.models.user import User
from app.repositories.user_repository import UserRepository

logger = logging.getLogger("fieldtrack.auth")

OTP_TTL_SECONDS = 10 * 60
OTP_MAX_ATTEMPTS = 5

# Constant-cost dummy hash for unknown-email logins (timing equalization).
_DUMMY_HASH = (
    "$2b$12$C6UzMDM.H6dfI/f/IKcEeO7ZBpC0mEAnH1JqGn0K8M1XGJ1qzqW1u"
)


class AuthService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.users = UserRepository(db)
        self.redis = get_redis()
        self.settings = get_settings()

    # ── Login ────────────────────────────────────────────────────────────
    async def login(
        self, email: str, password: str, ip: str | None
    ) -> tuple[str, str, int, User]:
        """Returns (access_token, refresh_token, expires_in_seconds, user)."""
        user = await self.users.get_by_email(email)
        if user is None:
            verify_password(password, _DUMMY_HASH)  # burn equal time
            raise invalid_credentials()
        if not verify_password(password, user.password_hash):
            raise invalid_credentials()
        if not user.is_active:
            raise user_inactive()

        access_token, _, _ = create_access_token(user.id, user.role.value)
        refresh_token, _, refresh_exp = create_refresh_token(user.id)

        # Single-session: overwrite any previous fingerprint.
        await self.redis.set(
            Keys.refresh_token(user.id),
            sha256_hex(refresh_token),
            ex=self.settings.refresh_token_expire_days * 86400,
        )

        self.users.add_audit_log(user_id=user.id, action="LOGIN", ip_address=ip)
        await self.db.commit()

        return (
            access_token,
            refresh_token,
            self.settings.access_token_expire_minutes * 60,
            user,
        )

    # ── Refresh (rotation + reuse detection) ─────────────────────────────
    async def refresh(
        self, refresh_token: str, ip: str | None
    ) -> tuple[str, str, int, User]:
        payload = verify_token(refresh_token, "refresh")
        user_id = int(payload["sub"])

        stored_fingerprint = await self.redis.get(Keys.refresh_token(user_id))
        if stored_fingerprint is None:
            raise token_invalid()  # logged out / expired session
        if stored_fingerprint != sha256_hex(refresh_token):
            # Valid JWT but not the CURRENT one => replay of a rotated-out
            # token. Revoke the whole session and audit.
            await self.redis.delete(Keys.refresh_token(user_id))
            self.users.add_audit_log(
                user_id=user_id,
                action="REFRESH_REUSE_DETECTED",
                ip_address=ip,
                metadata={"jti": payload["jti"]},
            )
            await self.db.commit()
            logger.warning("Refresh token reuse detected for user %s", user_id)
            raise token_invalid()

        user = await self.users.get_by_id(user_id)
        if user is None or not user.is_active:
            await self.redis.delete(Keys.refresh_token(user_id))
            raise user_inactive()

        # Rotate: blacklist old jti for its remaining life, issue + store new.
        await blacklist_token(payload["jti"], remaining_ttl_seconds(payload))
        access_token, _, _ = create_access_token(user.id, user.role.value)
        new_refresh, _, _ = create_refresh_token(user.id)
        await self.redis.set(
            Keys.refresh_token(user.id),
            sha256_hex(new_refresh),
            ex=self.settings.refresh_token_expire_days * 86400,
        )

        return (
            access_token,
            new_refresh,
            self.settings.access_token_expire_minutes * 60,
            user,
        )

    # ── Logout ───────────────────────────────────────────────────────────
    async def logout(
        self, user: User, access_payload: dict[str, Any], ip: str | None
    ) -> None:
        await blacklist_token(
            access_payload["jti"], remaining_ttl_seconds(access_payload)
        )
        await self.redis.delete(Keys.refresh_token(user.id))
        self.users.add_audit_log(user_id=user.id, action="LOGOUT", ip_address=ip)
        await self.db.commit()

    # ── Forgot / reset password ──────────────────────────────────────────
    async def forgot_password(self, email: str) -> None:
        """ALWAYS succeeds from the caller's perspective (no enumeration)."""
        user = await self.users.get_by_email(email)
        if user is None or not user.is_active:
            return

        otp = f"{secrets.randbelow(10**6):06d}"
        key = Keys.otp(email)
        # hash + attempts in one Redis HASH: one TTL governs both.
        await self.redis.hset(
            key, mapping={"hash": sha256_hex(otp), "attempts": 0}
        )
        await self.redis.expire(key, OTP_TTL_SECONDS)

        if self.settings.is_production:
            # TODO: wire FCM/email delivery. Raising (not silently logging)
            # so a dead reset flow can never reach users unnoticed.
            await self.redis.delete(key)
            raise ApiError(
                501,
                "Password reset delivery is not configured",
                "OTP_DELIVERY_NOT_CONFIGURED",
            )
        logger.warning("DEV ONLY — password reset OTP for %s: %s", email, otp)

    async def reset_password(
        self, email: str, otp: str, new_password: str, ip: str | None
    ) -> None:
        key = Keys.otp(email)
        stored = await self.redis.hgetall(key)
        if not stored:
            raise invalid_otp()

        attempts = await self.redis.hincrby(key, "attempts", 1)
        if attempts > OTP_MAX_ATTEMPTS:
            await self.redis.delete(key)
            raise invalid_otp()

        if stored.get("hash") != sha256_hex(otp):
            raise invalid_otp()

        user = await self.users.get_by_email(email)
        if user is None or not user.is_active:
            await self.redis.delete(key)
            raise invalid_otp()  # don't leak account state at this stage either

        await self.users.set_password_hash(user, hash_password(new_password))
        await self.redis.delete(key)  # OTP single-use
        await self.redis.delete(Keys.refresh_token(user.id))  # kill session
        self.users.add_audit_log(
            user_id=user.id, action="PASSWORD_RESET", ip_address=ip
        )
        await self.db.commit()
