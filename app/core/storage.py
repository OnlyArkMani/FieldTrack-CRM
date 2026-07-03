"""S3-compatible object storage for reports + visit photos.

boto3 is synchronous, so every network-touching method here is meant to be
called via `asyncio.to_thread(...)` from async call sites — this module itself
stays plain sync to keep boto3 usage straightforward and testable.

Works against real AWS S3, Backblaze B2 (S3-compatible endpoint), MinIO,
DigitalOcean Spaces, etc. — the only per-provider knob is `s3_endpoint_url`
(empty = real AWS) and `s3_use_path_style` (needed by some self-hosted
providers like MinIO).
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from functools import lru_cache

import boto3
from botocore.client import Config as BotoConfig
from botocore.exceptions import ClientError

from app.core.config import get_settings

logger = logging.getLogger("fieldtrack.storage")


class ObjectNotFound(Exception):
    """Raised when a key doesn't exist in the bucket."""


class Storage:
    def __init__(self) -> None:
        settings = get_settings()
        self.bucket = settings.s3_bucket
        client_kwargs: dict = {
            "region_name": settings.s3_region,
            "config": BotoConfig(
                s3={"addressing_style": "path" if settings.s3_use_path_style else "auto"},
                signature_version="s3v4",
            ),
        }
        if settings.s3_endpoint_url:
            client_kwargs["endpoint_url"] = settings.s3_endpoint_url
        if settings.s3_access_key_id:
            client_kwargs["aws_access_key_id"] = settings.s3_access_key_id
            client_kwargs["aws_secret_access_key"] = settings.s3_secret_access_key
        self._client = boto3.client("s3", **client_kwargs)

    def upload_bytes(
        self, key: str, content: bytes, *, content_type: str | None = None
    ) -> None:
        extra = {"ContentType": content_type} if content_type else {}
        self._client.put_object(Bucket=self.bucket, Key=key, Body=content, **extra)

    def download_bytes(self, key: str) -> bytes:
        try:
            obj = self._client.get_object(Bucket=self.bucket, Key=key)
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
                raise ObjectNotFound(key) from exc
            raise
        return obj["Body"].read()

    def exists(self, key: str) -> bool:
        try:
            self._client.head_object(Bucket=self.bucket, Key=key)
            return True
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code")
            if code in ("404", "NoSuchKey"):
                return False
            raise

    def delete(self, key: str) -> None:
        # S3's delete_object is idempotent — no error if the key is already gone.
        self._client.delete_object(Bucket=self.bucket, Key=key)

    def presigned_url(
        self,
        key: str,
        *,
        expires_in: int,
        filename: str | None = None,
        content_type: str | None = None,
    ) -> str:
        params = {"Bucket": self.bucket, "Key": key}
        if filename:
            params["ResponseContentDisposition"] = f'attachment; filename="{filename}"'
        if content_type:
            params["ResponseContentType"] = content_type
        return self._client.generate_presigned_url(
            "get_object", Params=params, ExpiresIn=expires_in
        )

    def list_with_last_modified(self, prefix: str) -> list[tuple[str, datetime]]:
        """(key, last_modified UTC) for every object under prefix. Paginates —
        callers (pruning) may have more objects than a single 1000-key page."""
        results: list[tuple[str, datetime]] = []
        continuation_token: str | None = None
        while True:
            kwargs = {"Bucket": self.bucket, "Prefix": prefix}
            if continuation_token:
                kwargs["ContinuationToken"] = continuation_token
            resp = self._client.list_objects_v2(**kwargs)
            for obj in resp.get("Contents", []):
                lm = obj["LastModified"]
                if lm.tzinfo is None:
                    lm = lm.replace(tzinfo=timezone.utc)
                results.append((obj["Key"], lm))
            if not resp.get("IsTruncated"):
                break
            continuation_token = resp.get("NextContinuationToken")
        return results


@lru_cache
def get_storage() -> Storage:
    """Cached singleton, mirroring get_settings()."""
    return Storage()
