"""Object storage for reports + visit photos — backed by self-hosted MinIO.

boto3 is synchronous, so every network-touching method here is meant to be
called via `asyncio.to_thread(...)` from async call sites — this module itself
stays plain sync to keep boto3 usage straightforward and testable.

MinIO speaks the S3 API, so this is plain boto3 pointed at our own MinIO
container (`MINIO_ENDPOINT_URL`, `MINIO_USE_PATH_STYLE=true` by default) instead of
a third-party cloud account — no external credentials/billing to manage, and
the bucket is auto-provisioned at startup (see `ensure_bucket`). The client
still works unmodified against real AWS S3/Backblaze B2/DigitalOcean Spaces if
`MINIO_ENDPOINT_URL` is pointed there instead — nothing here is MinIO-specific
beyond the defaults.

TWO ENDPOINTS, ON PURPOSE (confirmed via live testing, not a hypothetical):
this backend and the actual file bytes both live inside the Docker network,
so `MINIO_ENDPOINT_URL` should be the docker-internal hostname (`minio:9000`) for
every real upload/download/exists/delete call. But presigned download URLs
are fetched directly by the BROWSER or mobile app, which cannot resolve that
internal hostname at all — they need `MINIO_PUBLIC_ENDPOINT_URL` instead (e.g.
`http://localhost:9000` in dev, `https://your-domain.com:9000` in prod). One
endpoint for the SDK's own traffic, one for what gets signed into URLs handed
to clients — the same boto3 client can't do both at once. Real AWS S3 doesn't
need this split (its one endpoint is already public), so
`MINIO_PUBLIC_ENDPOINT_URL` defaults to empty, meaning "same as MINIO_ENDPOINT_URL".
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


def _make_client(settings, *, endpoint_url: str):
    client_kwargs: dict = {
        "region_name": settings.minio_region,
        "config": BotoConfig(
            s3={"addressing_style": "path" if settings.minio_use_path_style else "auto"},
            signature_version="s3v4",
        ),
    }
    if endpoint_url:
        client_kwargs["endpoint_url"] = endpoint_url
    if settings.minio_access_key_id:
        client_kwargs["aws_access_key_id"] = settings.minio_access_key_id
        client_kwargs["aws_secret_access_key"] = settings.minio_secret_access_key
    return boto3.client("s3", **client_kwargs)


class Storage:
    def __init__(self) -> None:
        settings = get_settings()
        self.bucket = settings.minio_bucket
        # Internal client: every real upload/download/exists/delete call.
        self._client = _make_client(settings, endpoint_url=settings.minio_endpoint_url)
        # Public client: ONLY used to sign presigned URLs, so the signature's
        # embedded host matches what the browser/mobile client will actually
        # hit. Falls back to the internal endpoint when unset (real AWS/B2,
        # where there's only one true endpoint anyway).
        public_endpoint = settings.minio_public_endpoint_url or settings.minio_endpoint_url
        self._public_client = (
            self._client
            if public_endpoint == settings.minio_endpoint_url
            else _make_client(settings, endpoint_url=public_endpoint)
        )

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
        # Public client: the signature must be computed against the same host
        # the browser/mobile app will actually request — see the module
        # docstring for why this can differ from self._client's endpoint.
        return self._public_client.generate_presigned_url(
            "get_object", Params=params, ExpiresIn=expires_in
        )

    def ensure_bucket(self) -> None:
        """Best-effort startup provisioning against self-hosted MinIO: create
        the bucket if it doesn't exist yet (a fresh MinIO container starts
        with none).

        Every Gunicorn/Uvicorn worker process runs this at startup
        independently (there's no single "leader" process), so a `create_bucket`
        race between workers is expected, not an error — whichever worker
        loses the race gets BucketAlreadyOwnedByYou (MinIO/AWS both use this
        code, not BucketAlreadyExists, when the caller already owns it).

        NOTE — CORS is deliberately NOT configured here. Both boto3's
        `put_bucket_cors` and MinIO's own `mc cors set` fail identically
        against this image with "NotImplemented — A header you provided
        implies functionality that is not implemented" (confirmed live —
        this is a real platform limitation, not a client bug). MinIO doesn't
        support bucket-level CORS via the S3 API at all in this build, so the
        CORS headers browsers need for the 307-redirected presigned-URL fetch
        are added by the reverse proxy sitting in front of MinIO instead —
        see nginx.prod.conf's dedicated :9000 server block (and the
        dev-compose equivalent), not this module."""
        try:
            self._client.head_bucket(Bucket=self.bucket)
        except ClientError:
            try:
                self._client.create_bucket(Bucket=self.bucket)
                logger.info("created object storage bucket %s", self.bucket)
            except ClientError as exc:
                code = exc.response.get("Error", {}).get("Code")
                if code not in ("BucketAlreadyOwnedByYou", "BucketAlreadyExists"):
                    raise

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
