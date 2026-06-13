"""Async Redis client (redis-py asyncio).

Single connection-pool-backed client shared across the app. Key patterns and
TTLs are documented in docs/REDIS_KEYS.md — keep that file in sync with Keys.
"""
import redis.asyncio as aioredis

from app.core.config import get_settings

_client: aioredis.Redis | None = None


class Keys:
    """Central registry of every Redis key pattern (see docs/REDIS_KEYS.md)."""

    PREFIX = "fieldtrack"

    # Pub/sub channel: location ingestion publishes the updated user_id here;
    # the admin-live WebSocket subscribes and re-broadcasts a fresh snapshot.
    LOCATION_UPDATES_CHANNEL = "fieldtrack:location:updates"

    @staticmethod
    def location(user_id: int) -> str:
        return f"{Keys.PREFIX}:location:{user_id}"

    @staticmethod
    def attendance_state(user_id: int) -> str:
        return f"{Keys.PREFIX}:attendance:state:{user_id}"

    @staticmethod
    def blacklist(jti: str) -> str:
        return f"{Keys.PREFIX}:blacklist:{jti}"

    @staticmethod
    def rate_limit(user_id: int, endpoint: str) -> str:
        return f"{Keys.PREFIX}:ratelimit:{user_id}:{endpoint}"

    @staticmethod
    def sync_processed(payload_hash: str) -> str:
        return f"{Keys.PREFIX}:sync:processed:{payload_hash}"

    @staticmethod
    def report(report_id: str) -> str:
        # Holds the export job's status hash (status, format, path, owner...);
        # TTL = report_retention_minutes so status and file expire together.
        return f"{Keys.PREFIX}:report:{report_id}"

    @staticmethod
    def refresh_token(user_id: int) -> str:
        # Stores sha256 of the CURRENT refresh token — single active session
        # per user (deliberate: new login kicks the old device; an anti-
        # buddy-punching property for an attendance product).
        return f"{Keys.PREFIX}:refresh:{user_id}"

    @staticmethod
    def otp(email: str) -> str:
        return f"{Keys.PREFIX}:otp:{email}"

    @staticmethod
    def login_rate_limit(ip: str) -> str:
        return f"{Keys.PREFIX}:ratelimit:login:{ip}"


def get_redis() -> aioredis.Redis:
    """Lazy singleton — safe to import at module level, connects on first use."""
    global _client
    if _client is None:
        _client = aioredis.from_url(
            get_settings().redis_url,
            decode_responses=True,
            max_connections=20,
        )
    return _client


async def close_redis() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
