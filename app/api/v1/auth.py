"""Auth router — thin HTTP layer; all logic lives in AuthService.

WEB vs MOBILE refresh transport:
- mobile (default): refresh token in the response body; client sends it back
  in the X-Refresh-Token header.
- web: refresh token ONLY in an httpOnly cookie scoped to /api/v1/auth —
  invisible to JS (XSS containment), sent automatically on /refresh & /logout.
  Cookie is Secure in production, SameSite=lax.
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.dependencies import CurrentUser, get_db, login_rate_limit
from app.core.exceptions import not_authenticated
from app.schemas.auth import (
    ForgotPasswordRequest,
    LoginRequest,
    MessageResponse,
    ResetPasswordRequest,
    TokenResponse,
    UserOut,
)
from app.services.auth_service import AuthService

router = APIRouter(prefix="/auth", tags=["auth"])

REFRESH_COOKIE = "refresh_token"


def _client_ip(request: Request) -> str | None:
    return request.headers.get("x-real-ip") or (
        request.client.host if request.client else None
    )


def _set_refresh_cookie(response: Response, token: str) -> None:
    settings = get_settings()
    response.set_cookie(
        key=REFRESH_COOKIE,
        value=token,
        max_age=settings.refresh_token_expire_days * 86400,
        httponly=True,
        secure=settings.is_production,
        samesite="lax",
        path=f"{settings.api_v1_prefix}/auth",  # only auth endpoints ever see it
    )


def _extract_refresh_token(request: Request) -> str:
    """Mobile: X-Refresh-Token header. Web: httpOnly cookie."""
    token = request.headers.get("x-refresh-token") or request.cookies.get(
        REFRESH_COOKIE
    )
    if not token:
        raise not_authenticated()
    return token


@router.post(
    "/login",
    response_model=TokenResponse,
    dependencies=[Depends(login_rate_limit)],  # 5/IP/15min, 429 + Retry-After
)
async def login(
    body: LoginRequest,
    request: Request,
    response: Response,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TokenResponse:
    access, refresh, expires_in, user = await AuthService(db).login(
        body.email, body.password, _client_ip(request)
    )
    if body.client == "web":
        _set_refresh_cookie(response, refresh)
        refresh_out = None
    else:
        refresh_out = refresh
    return TokenResponse(
        access_token=access,
        refresh_token=refresh_out,
        expires_in=expires_in,
        user=UserOut.model_validate(user),
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh(
    request: Request,
    response: Response,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TokenResponse:
    token = _extract_refresh_token(request)
    access, new_refresh, expires_in, user = await AuthService(db).refresh(
        token, _client_ip(request)
    )
    # Mirror the transport the client used: cookie users get a rotated cookie.
    if request.cookies.get(REFRESH_COOKIE) and not request.headers.get(
        "x-refresh-token"
    ):
        _set_refresh_cookie(response, new_refresh)
        refresh_out = None
    else:
        refresh_out = new_refresh
    return TokenResponse(
        access_token=access,
        refresh_token=refresh_out,
        expires_in=expires_in,
        user=UserOut.model_validate(user),
    )


@router.post("/logout", response_model=MessageResponse)
async def logout(
    request: Request,
    response: Response,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MessageResponse:
    # token_payload was stashed by get_current_user — same verified token.
    await AuthService(db).logout(
        user, request.state.token_payload, _client_ip(request)
    )
    response.delete_cookie(
        REFRESH_COOKIE, path=f"{get_settings().api_v1_prefix}/auth"
    )
    return MessageResponse(detail="Logged out")


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser) -> UserOut:
    return UserOut.model_validate(user)


@router.post("/forgot-password", response_model=MessageResponse)
async def forgot_password(
    body: ForgotPasswordRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MessageResponse:
    await AuthService(db).forgot_password(body.email)
    # Identical response whether or not the account exists.
    return MessageResponse(detail="If the account exists, a reset code was sent")


@router.post("/reset-password", response_model=MessageResponse)
async def reset_password(
    body: ResetPasswordRequest,
    request: Request,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MessageResponse:
    await AuthService(db).reset_password(
        body.email, body.otp, body.new_password, _client_ip(request)
    )
    return MessageResponse(detail="Password updated. Please log in again.")
