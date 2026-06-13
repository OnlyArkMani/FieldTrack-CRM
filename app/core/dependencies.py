"""FastAPI dependencies: DB/Redis injection, auth chain, role guards,
rate limiting.

Auth chain per request:
  Bearer token -> verify signature/expiry/type -> Redis blacklist check
  -> load user -> is_active check. Role guards compose on top.

get_db / get_redis are re-exported here because routers import ALL
dependencies from this one module — a single import surface.
"""
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import get_db  # re-export
from app.core.exceptions import (
    forbidden,
    not_authenticated,
    rate_limited,
    token_revoked,
    user_inactive,
)
from app.core.redis import Keys, get_redis  # re-export
from app.core.security import is_blacklisted, verify_token
from app.models.enums import UserRole
from app.models.user import User

__all__ = [
    "get_db",
    "get_redis",
    "get_current_user",
    "get_current_active_user",
    "get_current_admin",
    "get_current_supervisor",
    "get_current_employee",
    "login_rate_limit",
    "CurrentUser",
    "bearer_scheme",
]

bearer_scheme = HTTPBearer(auto_error=False)

LOGIN_MAX_ATTEMPTS = 5
LOGIN_WINDOW_SECONDS = 15 * 60


async def get_current_user(
    request: Request,
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> User:
    if credentials is None:
        raise not_authenticated()

    payload = verify_token(credentials.credentials, "access")  # raises 401 w/ code

    if await is_blacklisted(payload["jti"]):
        raise token_revoked()

    user = await db.get(User, int(payload["sub"]))
    if user is None:
        raise token_revoked()  # user deleted after token issued
    if not user.is_active:
        raise user_inactive()

    # Stash the verified payload so /auth/logout can blacklist this exact jti
    # without re-decoding the header.
    request.state.token_payload = payload
    return user


# Spec alias: "any authenticated, active user". get_current_user already
# enforces is_active, so these are the same dependency.
get_current_active_user = get_current_user

CurrentUser = Annotated[User, Depends(get_current_user)]


async def get_current_admin(user: CurrentUser) -> User:
    if user.role != UserRole.ADMIN:
        raise forbidden("Admin access required")
    return user


async def get_current_supervisor(user: CurrentUser) -> User:
    """Supervisor OR admin — admins can do anything a supervisor can."""
    if user.role not in (UserRole.ADMIN, UserRole.SUPERVISOR):
        raise forbidden("Supervisor access required")
    return user


async def get_current_employee(user: CurrentUser) -> User:
    """Any authenticated active user (employees, supervisors, admins)."""
    return user


# ── Rate limiting ────────────────────────────────────────────────────────
async def login_rate_limit(request: Request) -> None:
    """5 login attempts per IP per 15 minutes. Fixed window: one INCR+EXPIRE,
    O(1) memory. Keyed by IP (not email) — pre-auth, so IP is all we trust.
    X-Real-IP is set by our Nginx; direct client.host is the fallback in dev.
    """
    ip = request.headers.get("x-real-ip") or (
        request.client.host if request.client else "unknown"
    )
    r = get_redis()
    key = Keys.login_rate_limit(ip)
    count = await r.incr(key)
    if count == 1:
        await r.expire(key, LOGIN_WINDOW_SECONDS)
    if count > LOGIN_MAX_ATTEMPTS:
        ttl = await r.ttl(key)
        raise rate_limited(retry_after_seconds=ttl if ttl > 0 else LOGIN_WINDOW_SECONDS)


async def per_user_rate_limit(request: Request, user: CurrentUser) -> None:
    """General per-user per-endpoint limiter for authenticated routes."""
    settings = get_settings()
    key = Keys.rate_limit(user.id, request.url.path)
    r = get_redis()
    count = await r.incr(key)
    if count == 1:
        await r.expire(key, 60)
    if count > settings.rate_limit_per_minute:
        ttl = await r.ttl(key)
        raise rate_limited(retry_after_seconds=ttl if ttl > 0 else 60)
