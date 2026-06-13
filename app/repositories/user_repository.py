"""User queries. Repositories do DB access ONLY — no business rules, no
commits (services own transactions), no HTTP exceptions."""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.misc import AuditLog
from app.models.user import User


class UserRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    async def get_by_email(self, email: str) -> User | None:
        result = await self.db.execute(select(User).where(User.email == email))
        return result.scalar_one_or_none()

    async def get_by_id(self, user_id: int) -> User | None:
        return await self.db.get(User, user_id)

    async def set_password_hash(self, user: User, password_hash: str) -> None:
        user.password_hash = password_hash
        self.db.add(user)

    def add_audit_log(
        self,
        *,
        user_id: int | None,
        action: str,
        ip_address: str | None = None,
        metadata: dict | None = None,
    ) -> None:
        self.db.add(
            AuditLog(
                user_id=user_id,
                action=action,
                entity_type="auth",
                metadata_=metadata,
                ip_address=ip_address,
            )
        )
