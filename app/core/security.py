"""JWT creation/verification, Redis blacklist, password hashing.

DECISIONS:
- PyJWT (not python-jose). Access and refresh tokens signed with DIFFERENT
  secrets so a leaked access key can't mint refresh tokens.
- Every token carries a jti (UUID4). Logout/rotation blacklists the jti in
  Redis with TTL = REMAINING token lifetime (longer is waste — after natural
  expiry the signature check rejects the token anyway).
- Refresh tokens carry no role claim: role is re-read from DB on refresh, so
  role changes take effect within one access-token lifetime (15 min) at most.
- verify_token raises ApiError(401) with a precise code: TOKEN_EXPIRED vs
  TOKEN_INVALID — mobile client uses the distinction to decide refresh vs
  force-logout.
- bcrypt via passlib (12 rounds). OTPs are hashed with sha256 — they live
  10 minutes and have a 5-attempt counter; bcrypt buys nothing there.
"""
import hashlib
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Literal

import jwt
from passlib.context import CryptContext

from app.core.config import get_settings
from app.core.exceptions import token_expired, token_invalid
from app.core.redis import Keys, get_redis

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

TokenType = Literal["access", "refresh"]


# ── Passwords ────────────────────────────────────────────────────────────
def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)


def sha256_hex(value: str) -> str:
    """For refresh-token fingerprints and OTP storage in Redis."""
    return hashlib.sha256(value.encode()).hexdigest()


# ── Token creation ───────────────────────────────────────────────────────
def _secret_for(token_type: TokenType) -> str:
    s = get_settings()
    return s.jwt_access_secret if token_type == "access" else s.jwt_refresh_secret


def create_access_token(
    user_id: int, role: str, jti: str | None = None
) -> tuple[str, str, datetime]:
    """Returns (token, jti, expires_at)."""
    s = get_settings()
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(minutes=s.access_token_expire_minutes)
    jti = jti or str(uuid.uuid4())
    payload = {
        "sub": str(user_id),
        "role": role,
        "type": "access",
        "jti": jti,
        "iat": now,
        "exp": expires_at,
    }
    return (
        jwt.encode(payload, _secret_for("access"), algorithm=s.jwt_algorithm),
        jti,
        expires_at,
    )


def create_refresh_token(user_id: int) -> tuple[str, str, datetime]:
    """Returns (token, jti, expires_at). No role claim — see module docstring."""
    s = get_settings()
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(days=s.refresh_token_expire_days)
    jti = str(uuid.uuid4())
    payload = {
        "sub": str(user_id),
        "type": "refresh",
        "jti": jti,
        "iat": now,
        "exp": expires_at,
    }
    return (
        jwt.encode(payload, _secret_for("refresh"), algorithm=s.jwt_algorithm),
        jti,
        expires_at,
    )


# ── Token verification ───────────────────────────────────────────────────
def verify_token(token: str, token_type: TokenType = "access") -> dict[str, Any]:
    """Decode + validate signature, expiry, and type. Raises ApiError(401)."""
    s = get_settings()
    try:
        payload = jwt.decode(
            token,
            _secret_for(token_type),
            algorithms=[s.jwt_algorithm],
            options={"require": ["sub", "exp", "jti", "type"]},
        )
    except jwt.ExpiredSignatureError:
        raise token_expired()
    except jwt.PyJWTError:
        raise token_invalid()
    if payload.get("type") != token_type:
        raise token_invalid()
    return payload


def remaining_ttl_seconds(payload: dict[str, Any]) -> int:
    """Seconds until this token's natural expiry (>= 1 so SET EX never gets 0)."""
    exp = datetime.fromtimestamp(payload["exp"], tz=timezone.utc)
    return max(1, int((exp - datetime.now(timezone.utc)).total_seconds()))


# ── Redis blacklist ──────────────────────────────────────────────────────
async def blacklist_token(jti: str, ttl_seconds: int) -> None:
    await get_redis().set(Keys.blacklist(jti), "1", ex=max(1, ttl_seconds))


async def is_blacklisted(jti: str) -> bool:
    return bool(await get_redis().exists(Keys.blacklist(jti)))
