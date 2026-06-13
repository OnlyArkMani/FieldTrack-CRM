"""Consistent error responses: every error is {"detail": ..., "code": ...}.

RULE: application code raises ApiError (never bare HTTPException). The
handlers in main.py render ApiError directly and retrofit a code onto any
HTTPException raised by FastAPI internals (e.g. HTTPBearer), so the contract
holds for 100% of error responses.
"""
from typing import Any


class ApiError(Exception):
    def __init__(
        self,
        status_code: int,
        detail: str,
        code: str,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.status_code = status_code
        self.detail = detail
        self.code = code
        self.headers = headers
        super().__init__(detail)

    def body(self) -> dict[str, Any]:
        return {"detail": self.detail, "code": self.code}


# Default codes for HTTPExceptions raised by framework internals.
DEFAULT_ERROR_CODES: dict[int, str] = {
    400: "BAD_REQUEST",
    401: "NOT_AUTHENTICATED",
    403: "FORBIDDEN",
    404: "NOT_FOUND",
    409: "CONFLICT",
    422: "VALIDATION_ERROR",
    429: "RATE_LIMITED",
    500: "INTERNAL_ERROR",
}


# ── Canonical auth errors (single definition, raised from anywhere) ──────
def invalid_credentials() -> ApiError:
    # Same message for unknown email and wrong password — no user enumeration.
    return ApiError(401, "Invalid email or password", "INVALID_CREDENTIALS")


def token_expired() -> ApiError:
    return ApiError(
        401, "Token has expired", "TOKEN_EXPIRED",
        headers={"WWW-Authenticate": "Bearer"},
    )


def token_invalid() -> ApiError:
    return ApiError(
        401, "Invalid token", "TOKEN_INVALID",
        headers={"WWW-Authenticate": "Bearer"},
    )


def token_revoked() -> ApiError:
    return ApiError(
        401, "Token has been revoked", "TOKEN_REVOKED",
        headers={"WWW-Authenticate": "Bearer"},
    )


def not_authenticated() -> ApiError:
    return ApiError(
        401, "Not authenticated", "NOT_AUTHENTICATED",
        headers={"WWW-Authenticate": "Bearer"},
    )


def user_inactive() -> ApiError:
    return ApiError(401, "User account is inactive", "USER_INACTIVE")


def forbidden(detail: str = "Insufficient permissions") -> ApiError:
    return ApiError(403, detail, "FORBIDDEN")


def rate_limited(retry_after_seconds: int) -> ApiError:
    return ApiError(
        429,
        "Too many attempts. Try again later.",
        "RATE_LIMITED",
        headers={"Retry-After": str(retry_after_seconds)},
    )


def invalid_otp() -> ApiError:
    return ApiError(400, "Invalid or expired OTP", "INVALID_OTP")


# ── Resource errors (CRUD) ───────────────────────────────────────────────
def not_found(detail: str = "Resource not found") -> ApiError:
    return ApiError(404, detail, "NOT_FOUND")


def conflict(detail: str = "Resource already exists") -> ApiError:
    return ApiError(409, detail, "CONFLICT")


def bad_request(detail: str = "Bad request") -> ApiError:
    return ApiError(400, detail, "BAD_REQUEST")
