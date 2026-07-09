# FieldTrack — Backend Architecture

Foundation document. Every structural decision and its reasoning lives here.

## Directory structure

```
FieldTrack/
├── docker-compose.yml      # postgres+postgis, redis, app, nginx
├── Dockerfile              # multi-stage, non-root, python:3.11-slim
├── .env.example            # all config — copy to .env, never commit .env
├── requirements.txt
├── alembic.ini             # no DB URL inside — env.py reads DATABASE_URL
├── nginx/
│   └── nginx.conf          # /api → fastapi, / → static SPA, per-IP rate limit
├── static/                 # future admin web build output (served by nginx)
├── alembic/
│   ├── env.py              # async migrations, PostGIS tables excluded
│   ├── script.py.mako
│   └── versions/
│       └── 0001_initial_schema.py
├── docs/
│   └── REDIS_KEYS.md       # every Redis key pattern + TTL + justification
├── app/
│   ├── main.py             # FastAPI app, lifespan, CORS, /health
│   ├── core/               # cross-cutting infrastructure
│   │   ├── config.py       #   pydantic-settings, fail-fast on missing secrets
│   │   ├── security.py     #   JWT (PyJWT, separate access/refresh secrets), bcrypt
│   │   ├── database.py     #   async engine + session dependency
│   │   ├── redis.py        #   async client + Keys registry
│   │   └── dependencies.py #   get_current_user, role guards, rate limiter
│   ├── api/                # HTTP layer ONLY — routers per domain, zero logic
│   │   └── v1/             #   auth.py, users.py, teams.py, attendance.py,
│   │                       #   locations.py, geofences.py, notifications.py,
│   │                       #   sync.py, reports.py, dashboard.py (added per feature)
│   ├── schemas/            # Pydantic v2 request/response models per domain
│   ├── services/           # business logic; owns transactions (commit/rollback)
│   ├── repositories/       # DB queries ONLY — no business rules, no commits
│   ├── models/             # SQLAlchemy ORM (see Schema decisions below)
│   ├── workers/            # APScheduler jobs: attendance reminders, rollup
│   │                       # recompute, geofence event processing, FCM retries
│   └── utils/              # pure helpers: haversine, export builders (csv/xlsx/pdf)
└── tests/
```

**Layering rule (enforced by review, the structure makes violations obvious):**
`api → services → repositories → models`. Routers never touch the DB;
repositories never raise HTTP exceptions; services own transaction boundaries.
This is what makes the codebase survivable for a solo dev — every bug has one
layer it can live in.

## Explicit decisions (and the assumptions behind them)

**Async throughout, asyncpg, SQLAlchemy 2.0.** The workload is many small
IO-bound requests (location pings) — exactly what async buys you on 2 vCPU.

**No Celery / no message broker.** Background needs (reminders, rollups,
retries) are periodic, not event-driven, and must fit in 4 GB RAM. APScheduler
runs in-process. At 100 employees this still holds — the math: 100 employees
× worst-case 2-min pings ≈ 0.8 req/s sustained. FastAPI on 2 workers handles
hundreds. **Zero architecture change to 100 is real, not aspirational.**

**JWT: PyJWT, separate access/refresh secrets, jti-based Redis blacklist.**
Separate secrets contain a leak; jti blacklist gives real logout despite
stateless tokens; refresh rotation with a Redis allowlist detects token theft.

**ASSUMPTION — password column.** The spec's users table had no credential
field, but JWT auth requires one. Added `password_hash` (bcrypt). If you
later want OTP-only login, it becomes nullable in a 2-line migration.

**ASSUMPTION — `supervisors` table dropped.** The earlier table list had a
separate `supervisors` table; the final schema models it as
`teams.supervisor_id → users.id` + `role=SUPERVISOR`, which is normalized and
was implied by your column spec. One supervisor per team; a supervisor's
scope = their team's members.

**Circular FK users↔teams** handled with `use_alter` (ORM) and
create-teams → create-users → ALTER (migration). Standard, deterministic.

**BigInteger PKs everywhere.** Only location_logs strictly needs it (~11M
rows/yr at 100 employees), but mixed PK widths cause FK type friction later.

**location_logs has NO PostGIS column — deliberately.** Geometry on the
hottest write path costs CPU per insert, and every spatial question we ask
("is this ping inside zone X?") is answered against `geofences.zone` with
`ST_Contains(zone, ST_SetSRID(ST_MakePoint(lng,lat),4326))`, which needs no
geometry on the ping. GIST index lives on `geofences.zone` where it pays.
If track-line analytics are ever needed, add a generated geometry column then.

**Two timestamps on location_logs.** `timestamp` = device capture time (the
truth for tracks; offline sync delivers old pings), `created_at` = server
arrival. Their delta is the sync-lag metric for free.

**Partial indexes** on `location_logs(sync_status) WHERE PENDING` and
`device_info(fcm_token) WHERE NOT NULL` — index only the rows queries touch.

**Native Postgres enums** for domain states (role, attendance status, session
type, sync status, geofence event), **plain varchar** for open-ended
categories (notification.type, sync_queue.status) that will grow — pg enum
changes require migrations; varchar doesn't.

**timestamptz everywhere, server in UTC.** Mobile clients localize. Naive
datetimes are banned.

**settings.user_id NULL = global setting**, with a partial unique index
because Postgres unique constraints don't deduplicate NULLs.

**audit_logs.user_id is SET NULL on delete** — audit history must outlive the
user. Critical events only (login, attendance changes, role changes), per
project decision.

**Redis is never the source of truth.** Every key is reconstructible from
Postgres; every key has a TTL; eviction policy `volatile-lru`. See
`docs/REDIS_KEYS.md`.

**Resource budget on the 4 GB VPS:** postgres 1g + redis 256m + app 1g +
nginx 128m ≈ 2.4 GB committed, ~1.6 GB OS/headroom. Postgres tuned to the
budget in the compose command block.

**Ports:** nginx on `${NGINX_HTTP_PORT:-8090}` (8080/8081 unavailable on the
dev machine), Postgres host-side on 5433 (existing dockerized Postgres owns
5432), Redis on 6380. PG and Redis bind to 127.0.0.1 only — never public.

**FCM:** the legacy "server key" is deprecated by Google; config takes a
service-account JSON path + project id for the HTTP v1 API instead.

**TLS** is intentionally deferred to certbot on the VPS once a domain exists
(a 443 server block in nginx.conf, no app changes).

## Scaling story to 100 employees (config-only)

| Knob | Now | At 100 |
|---|---|---|
| `DB_POOL_SIZE` | 10 | 20 |
| `UVICORN_WORKERS` | 2 | 2–3 (or bump vCPU) |
| Postgres `shared_buffers` | 256MB | 512MB (if RAM raised) |
| Redis maxmemory | 200mb | unchanged (≪1 MB used) |
| Schema/code | — | **unchanged** |

## Getting started

```bash
cp .env.example .env        # fill secrets: openssl rand -hex 32
docker compose up -d --build
docker compose exec app alembic upgrade head
curl http://localhost:8090/api/v1/health
```
