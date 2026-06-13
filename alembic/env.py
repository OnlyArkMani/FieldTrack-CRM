"""Alembic environment — async engine, URL from environment.

DECISIONS:
- URL comes from DATABASE_URL env var (falls back to app settings/.env);
  never stored in alembic.ini.
- include_object filters out PostGIS-internal tables (spatial_ref_sys) so
  autogenerate never tries to drop them.
- Runs migrations through the async engine (same driver as the app).
"""
import asyncio
import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from app.models import Base  # imports ALL models — metadata is complete

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

database_url = os.environ.get("DATABASE_URL")
if not database_url:
    from app.core.config import get_settings

    database_url = get_settings().database_url
config.set_main_option("sqlalchemy.url", database_url)

target_metadata = Base.metadata

POSTGIS_TABLES = {"spatial_ref_sys"}


def include_object(obj, name, type_, reflected, compare_to):
    if type_ == "table" and name in POSTGIS_TABLES:
        return False
    return True


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        include_object=include_object,
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        include_object=include_object,
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
