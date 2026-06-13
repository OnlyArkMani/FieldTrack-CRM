"""Async SQLAlchemy engine + session factory.

DECISIONS:
- SQLAlchemy 2.0 async with asyncpg. pool_size=10 + max_overflow=5 per worker
  (2 workers => max 30 connections, well under Postgres max_connections=50).
  At 100 employees, raise DB_POOL_SIZE in .env — zero code change.
- pool_pre_ping=True: VPS-local network is reliable, but Postgres restarts
  (deploys, OOM) would otherwise poison the pool.
- expire_on_commit=False: standard for async — avoids surprise lazy-load IO
  after commit.
"""
from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.core.config import get_settings

settings = get_settings()

engine = create_async_engine(
    settings.database_url,
    pool_size=settings.db_pool_size,
    max_overflow=settings.db_max_overflow,
    pool_pre_ping=True,
    echo=False,
)

async_session_factory = async_sessionmaker(
    engine, class_=AsyncSession, expire_on_commit=False
)


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """FastAPI dependency. One session per request; commit/rollback explicit
    in services — the dependency only guarantees cleanup."""
    async with async_session_factory() as session:
        yield session
