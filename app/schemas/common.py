"""Shared schema primitives — cursor pagination.

WHY CURSOR (KEYSET) NOT OFFSET:
- OFFSET N makes Postgres scan and discard N rows; at page 500 that's a
  500-page scan per request. Keyset pagination (`WHERE id > :cursor`) walks
  the index from where the last page ended — O(page size), flat at any depth.
- The cursor is an OPAQUE base64 token (the last row's id). Opaque so clients
  can't hand-craft it or build assumptions on its shape; we can change the
  encoding (compound keys later) without breaking the API contract.
- Ordering is by `id ASC` (monotonic, unique, indexed PK) — a stable total
  order, which keyset pagination requires. The mobile list sorts/searches for
  display on top of this; the wire order just has to be deterministic.
"""
import base64
import binascii
from typing import Generic, TypeVar

from pydantic import BaseModel

T = TypeVar("T")


def encode_cursor(last_id: int) -> str:
    """Opaque forward cursor = base64('id:{last_id}')."""
    return base64.urlsafe_b64encode(f"id:{last_id}".encode()).decode()


def decode_cursor(cursor: str | None) -> int | None:
    """Returns the last-seen id, or None for first page / malformed cursor.

    A malformed cursor degrades to "first page" rather than 400 — a stale or
    truncated token from an old client shouldn't hard-fail the list.
    """
    if not cursor:
        return None
    try:
        raw = base64.urlsafe_b64decode(cursor.encode()).decode()
        prefix, _, value = raw.partition(":")
        if prefix != "id":
            return None
        return int(value)
    except (binascii.Error, ValueError, UnicodeDecodeError):
        return None


class CursorPage(BaseModel, Generic[T]):
    """Uniform list envelope for every paginated endpoint."""

    items: list[T]
    next_cursor: str | None = None
    total: int
    has_more: bool
