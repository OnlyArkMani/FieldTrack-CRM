"""Auth request/response schemas (Pydantic v2).

VALIDATION DECISIONS:
- Email lowercased at the schema boundary — the DB unique index is on the
  lowercased value, so normalization happens in exactly one place.
- Password min 8 chars (max 128 to bound bcrypt input; bcrypt truncates at
  72 bytes anyway).
- OTP is exactly 6 digits, pattern-enforced.
- client field on login: "mobile" (default) gets the refresh token in the
  body; "web" gets it ONLY as an httpOnly cookie (XSS containment).
"""
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from app.models.enums import UserRole


class _LowercaseEmail(BaseModel):
    email: EmailStr

    @field_validator("email", mode="after")
    @classmethod
    def _lowercase(cls, v: str) -> str:
        return v.lower()


class LoginRequest(_LowercaseEmail):
    password: str = Field(min_length=8, max_length=128)
    client: Literal["web", "mobile"] = "mobile"


class ForgotPasswordRequest(_LowercaseEmail):
    pass


class ResetPasswordRequest(_LowercaseEmail):
    otp: str = Field(pattern=r"^\d{6}$")
    new_password: str = Field(min_length=8, max_length=128)


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    email: str
    phone: str | None
    role: UserRole
    team_id: int | None
    profile_photo_url: str | None
    is_active: bool


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str | None = None  # None for web clients (cookie instead)
    token_type: Literal["bearer"] = "bearer"
    expires_in: int  # access token lifetime in seconds, for client timers
    user: UserOut


class MessageResponse(BaseModel):
    detail: str
