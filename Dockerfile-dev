# FieldTrack FastAPI image — multi-stage, non-root, slim.
# DECISION: python:3.11-slim (not alpine) — manylinux wheels (asyncpg,
# pydantic-core, shapely) install without compilation; alpine forces builds.

FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Non-root user — never run app containers as root in production.
RUN groupadd -r fieldtrack && useradd -r -g fieldtrack fieldtrack

COPY --from=builder /install /usr/local
WORKDIR /srv/fieldtrack
COPY alembic.ini ./
COPY alembic ./alembic
COPY app ./app

# Report exports dir, owned by the non-root user. Mounted as a named volume in
# compose; Docker copies this dir's ownership to the fresh volume on first use,
# so the app can write exports without running as root.
RUN mkdir -p /srv/fieldtrack/reports \
    && chown -R fieldtrack:fieldtrack /srv/fieldtrack/reports

USER fieldtrack
EXPOSE 8000

# 2 workers = 2 vCPU. At higher load raise via UVICORN_WORKERS env, not code.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${UVICORN_WORKERS:-2} --proxy-headers --forwarded-allow-ips '*'"]
