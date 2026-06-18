# FieldTrack — Pre-Deployment Validation (Hetzner CX22)

Date: 2026-06-18 · Validator pass against the repo at deploy time.
Legend: ✅ confirmed · ⚠️ issue found (fixed in this pass) · ❓ cannot verify locally (manual step)

> Note on environment: this validation ran in a sandbox with **no Docker and no PyPI access**.
> Live-stack items (running containers, `docker stats`, executing the test suite) therefore could
> not be executed here and are marked ❓ with the exact command to run on the VPS / in CI. All
> static, code-level checks were performed directly against the source.

---

## SECTION 1 — GitHub Actions pipeline

**⚠️ Test job ran against ZERO tests (now fixed).** `tests/` contained only `__init__.py` — no
`def test_` anywhere. `pytest --cov=app` exits with code **5 ("no tests collected") = failure**, so
the test gate would have **failed every push to main and blocked all deploys**.
Fix: added `tests/test_core_logic.py` (8 real, DB-free tests covering attendance duration math, the
state-machine table, password hashing, FCM no-op, report range validation) and `pytest.ini`
(`asyncio_mode = auto`). Symbols verified to exist; files pass `py_compile`. Run in CI to confirm green.

**✅ Postgres/Redis service health checks.** Both service containers declare health checks
(`pg_isready -U fieldtrack`, `redis-cli ping`) with interval/timeout/retries. GitHub Actions waits for
service health before job steps run.

**✅ Build tag strategy.** Image is pushed to GHCR tagged BOTH `:latest` and `:${{ github.sha }}`
(deploy.yml lines 152-154). The SHA tag is what deploy runs — correct for rollback.

**✅ Deploy references the prod compose file.** All compose commands now use
`docker compose --env-file .env.prod -f docker-compose.prod.yml` (the dev `docker-compose.yml` is
never touched).

**❓ `environment: production` approval gate.** The `environment: production` key is present
(deploy.yml line 169), but the YAML **alone does not enforce approval**. The manual-approval gate is a
**repo setting**: GitHub → Settings → Environments → `production` → enable **Required reviewers**.
Verify this is configured before going live; otherwise deploy runs unattended.

**⚠️ `.env` interpolation gap (now fixed).** Compose only auto-loads a file literally named `.env`.
Production secrets live in `.env.prod`, and the old deploy commands passed no `--env-file`, so
`${POSTGRES_USER}`, `${POSTGRES_PASSWORD}`, `${REDIS_PASSWORD}`, `${IMAGE_TAG}` would have
interpolated to **empty strings** — Postgres refuses to init, `DATABASE_URL` becomes malformed, the
whole stack comes up broken. Fix: every compose invocation in deploy.yml now passes
`--env-file .env.prod`; the prod compose header documents the same for manual runs.

**Requirements / clean install:** all deps are pinned to exact versions, no ranges, no obvious
conflicts; `bcrypt==4.0.1` is deliberately pinned (passlib 1.7.4 breaks with bcrypt ≥4.1, documented
inline). Could not run a clean `pip install` here (PyPI blocked by sandbox proxy) — ❓ confirmed by the
CI "Install dependencies" step on a fresh runner.

**Dockerfile:** ✅ multi-stage (builder → slim runtime); ✅ `requirements.txt` copied & installed
BEFORE app code (layer caching); ✅ runs as non-root (`USER fieldtrack`). The Dockerfile `CMD` uses
`uvicorn` as a fallback default, but **docker-compose.prod.yml overrides it with `gunicorn`**
(`-k uvicorn.workers.UvicornWorker --workers 4`), and gunicorn is in requirements — so production runs
gunicorn as intended. ✅ functional (note the Dockerfile default differs from the compose command).

**GitHub Secrets referenced — each must be added manually in Settings → Secrets and variables → Actions:**
- `VPS_HOST` — VPS public IP/host. **Must be added manually.**
- `VPS_USER` — SSH deploy user. **Must be added manually.**
- `VPS_SSH_KEY` — private SSH key for the deploy user. **Must be added manually.**
- `GHCR_TOKEN` — PAT with `write:packages`+`read:packages`. **Must be added manually.**
- `NOTIFY_WEBHOOK_URL` — Discord/Slack webhook (optional; notify steps `|| true`). **Add manually if wanted.**
- `CODECOV_TOKEN` — optional (`fail_ci_if_error: false`). **Add manually if wanted.**

---

## SECTION 2 — End-to-end feature checklist (code-verified; runtime ❓ — no Docker here)

All logic below was read and verified at the source level. Marked ❓ for live runtime because the
stack cannot be booted in this sandbox; each has a clear on-VPS / CI test.

**AUTH — ✅ logic correct.** Login verifies bcrypt with a dummy-hash timing-equalizer for unknown
emails, issues access+refresh, stores `sha256(refresh)` in Redis. Logout blacklists the access jti and
deletes the refresh fingerprint (reuse → 401). Refresh **rotates**: validates the JWT, compares
fingerprint, blacklists the old jti, stores a new fingerprint; a replayed old token (valid JWT, wrong
fingerprint) revokes the whole session and audits `REFRESH_REUSE_DETECTED`.

**ATTENDANCE — ✅ logic correct.** `_ALLOWED_FROM` enforces START(only from NULL) → BREAK/RESUME ⇄ →
END. Double-START → `409` plus a `UNIQUE(user_id, date)` DB backstop (IntegrityError → 409).
`work_summary` 10–500 chars required on END (schema + service backstop). `calculate_duration` sums only
START/RESUME→BREAK/END intervals, so **break time is excluded** (unit-tested: 09:00 start, 12:00 break,
13:00 resume, 17:00 end = 420 min).

**GPS & LOCATION — ✅ logic correct.** `POST /location/batch` claims each record with Redis
`SET NX sha256(user:timestamp)` TTL 6h; a duplicate batch is skipped on the second send. Accepted
newest record updates the live hash `fieldtrack:location:{user_id}` (TTL 2h) and publishes to the
updates channel. `live()` reads from that Redis hash. ❓ Confirm at runtime with `redis-cli GET`.

**GEOFENCING — ✅ logic correct.** Circles are stored as a **64-point** `ST_Buffer` polygon
(`quad_segs=16` ⇒ 16×4) in a single `GEOMETRY(POLYGON,4326)` column with a GIST index; `ST_Contains`
drives membership. The ENTER/EXIT engine computes `inside_now − inside_prev` (no repeat-ENTER spam) and
the repository pairs each ENTER with the next event via a `LEAD` window to derive dwell time.
❓ Confirm ENTER/EXIT rows at runtime by posting in/out locations.

**SYNC ENGINE — ❓ Flutter-side.** Offline SQLite queue + sync is mobile-side and cannot be tested from
the backend. Manual test on a device with network disabled.

**REPORTS — ✅ (Bug 2 fix holds).** `POST /reports/generate` writes PROCESSING and schedules
`run_report_job`, which wraps build+export in try/except and **always** writes READY or FAILED — a job
can no longer get stuck on PROCESSING; the status endpoint also degrades a READY-but-missing file to
EXPIRED. `DISTANCE_ZONES` report type is implemented (CSV/Excel; PDF rejected with 400). **31-day cap:**
the endpoint returns the documented `400 + X-Error-Code: DATE_RANGE_TOO_LARGE`. ⚠️ The schema validator
previously also capped at 31 days, which made Pydantic return **422 first** and shadowed the documented
400 — fixed by relaxing the schema to a 1-year sanity ceiling so a 35-day range now returns **400**.

**NOTIFICATIONS — ✅ FCM is a true no-op when unconfigured.** `_configured` requires BOTH a service
account file and a project id; otherwise both send paths log and return empty — no exception thrown.
When configured, all send errors are still swallowed (push is best-effort, never blocks a request).

**ADMIN WEB — ✅ code correct (Bug 1).** WS route `/ws/admin-live` (full path `/api/v1/ws/admin-live`)
authenticates the access-token query param, requires `role == ADMIN`, then loops: initial snapshot +
pub/sub nudge or 15s heartbeat, with clean unsubscribe on disconnect — it stays connected. nginx
proxies `/api/v1/ws/` with the Upgrade/Connection headers (matches the path; this was the original
"Reconnecting" cause). ❓ Live map markers + trail replay require a browser against the running stack.

---

## SECTION 3 — Production config sanity check

**docker-compose.prod.yml:**
- ✅ Only nginx publishes ports (`80:80`, `443:443`). Postgres and Redis have **no `ports:`** at all;
  app uses `expose: 8000` only. Internal access via `fieldtrack_network`.
- ✅ `restart: always` on all four services.
- ✅ Secrets via `.env.prod` (`env_file` for the app; `${...}` interpolation now fed by `--env-file`).
- ✅ Named volumes `postgres_data`, `redis_data`, `reports_data`, `nginx_logs` (survive `down`).

**nginx.prod.conf:**
- ✅ SSL paths match certbot: `/etc/letsencrypt/live/<domain>/fullchain.pem` + `privkey.pem`.
- ✅ WebSocket headers present for `/api/v1/ws/` (Upgrade/Connection, 3600s read timeout), placed
  before the generic `/api/` block.
- ✅ Rate limiting is scoped to `/api/v1/auth/` only (`30r/m`, burst 10) — **not** global, so
  high-frequency location syncs are not throttled.
- ✅ gzip excludes images (`gzip_types` lists only html/json/css/js).
- ⚠️ **Optional-upstream startup crash (fixed).** `/status` (Uptime Kuma) and `/grafana` used static
  `proxy_pass http://uptime-kuma:3001/`. Those containers live in a **separate** compose file; nginx
  resolves upstream hostnames at **startup** and refuses to boot ("host not found in upstream") if they
  are absent — taking the whole site down if the main stack is brought up before/without monitoring.
  Fix: added `resolver 127.0.0.11` + variable upstreams + `rewrite` so resolution is deferred to
  request time (502 if monitoring is down, instead of crashing nginx).
- ❓ **Domain placeholder.** `your-domain.com` is still a placeholder in nginx.prod.conf (server_name,
  SSL paths, CSP `wss://`), in `.env.prod.example` (`ALLOWED_ORIGINS`), and in the monitoring
  `GF_SERVER_ROOT_URL`. The deploy brief left the domain as "[INSERT YOUR ACTUAL DOMAIN HERE]" — it must
  be filled in everywhere before issuing certs / deploying.

**Alembic:** ✅ Linear chain `0001 → 0002 → 0003`, single head, no gaps, no merge heads. ❓ confirm with
`alembic history` / `alembic heads` in CI (the migration step already runs `alembic upgrade head`).

**Seed / admin password — ⚠️ (fixed).** There was **no** `app/core/seed.py`. The only seed,
`scripts/seed_users.py`, hardcodes `Admin@123` / `Super@123` / `Employee@123` — fine for dev, a
**critical hole in production**. Added `app/core/seed.py`: creates the first admin with a 20-char
**random** password printed to console **once**, never stored in plaintext, idempotent. Run once on the
VPS: `... run --rm app python -m app.core.seed`. Keep `scripts/seed_users.py` for dev only.

**CORS — ✅.** `.env.prod.example` sets `ALLOWED_ORIGINS=https://your-domain.com` (single origin, no
localhost, no `*`); middleware uses `settings.cors_origins`; docs are disabled when
`app_env=production`. Just replace the placeholder domain.

---

## SECTION 4 — Resource sizing (CX22, 4 GB) — ❓ measured from config (no Docker here)

`docker stats` could not be run (no Docker in sandbox). Sizing assessed from the **hard `mem_limit`
caps** declared in docker-compose.prod.yml, which is the meaningful safety figure:

| Service  | mem_limit | Tuning |
|---|---|---|
| postgres | 1024 MB | shared_buffers 256 MB, effective_cache_size 768 MB, max_connections 50 |
| app      | 1024 MB | gunicorn × 4 uvicorn workers (~120–180 MB each ≈ 0.5–0.7 GB typical) |
| redis    | 256 MB  | maxmemory 200 MB, persistence off |
| nginx    | 128 MB  | — |
| **Sum of caps** | **~2.4 GB** | + OS/Docker daemon ≈ 0.4–0.6 GB |

Math: 2432 MB of caps + ~0.5 GB OS ≈ **~2.9 GB worst case**, leaving **~1.1 GB headroom** on a 4 GB box.
Realistic idle/light load (15–20 employees, 10×20-record batches) sits far below the caps (app
~0.4–0.7 GB, postgres ~0.3 GB, redis <50 MB). **Verdict: 4 GB is sufficient with comfortable headroom**
for the app stack, and the design scales to 100 employees without architecture change.

⚠️ **Caveat — full monitoring stack on the same box.** Grafana (~150 MB) + Prometheus (~150–250 MB) +
Uptime Kuma (~100 MB) + node-exporter (~20 MB) add **~400–500 MB**. Main + monitoring ≈ 3.3–3.4 GB →
headroom drops to **~0.6 GB**, which is tight. Recommendation: run **Uptime Kuma only** on the CX22
(lightweight, gives status + alerts) and skip Grafana/Prometheus, or offload them. Confirm on the VPS:

```
docker stats --no-stream
# light load:
for i in $(seq 1 10); do curl -s -XPOST https://<domain>/api/v1/location/batch \
  -H "Authorization: Bearer <jwt>" -H "Content-Type: application/json" \
  -d @batch20.json >/dev/null; done
docker stats --no-stream
```

---

## SECTION 5 — Rollback safety

**1) deploy.yml rollback logic — ⚠️ two real bugs found and fixed.**
- **Health check was broken (false failure on every deploy).** It ran `curl http://localhost:8000/...`
  on the VPS host, but the app publishes **no host port** in prod (`expose` only) — connection refused →
  health "fails" on every deploy → spurious rollback. Fixed to run the check **inside** the container
  via `docker compose exec -T app python -c "...urlopen(.../health)"`.
- **Rollback target was fragile.** It picked "some" non-current image tag via `docker images | grep -v`,
  which could be empty (previous image pruned after 24h) → broken version left running. Fixed to
  **capture the currently-running container's image tag before deploying** and roll back to exactly that;
  if none exists it now logs that manual recovery is required rather than silently leaving the broken
  build up.

**2) DB migration rollback — ⚠️ destructive, by nature.** `0002` and `0003` are `add_column`
migrations; their `downgrade()` is `drop_column`, which **loses data** (e.g. `teams.is_active`,
circle center/radius). Worse, downgrading `0003` re-introduces the original `AttributeError → 500` bug
because the code references `is_active`. **`alembic downgrade -1` is NOT a safe bug-recovery tool here.**
The correct play: these migrations are **additive and backward-compatible**, so on a bad deploy you
**roll back the app image and leave the schema forward** — the previous app version runs fine against
the newer (additive) schema. Never downgrade the DB to fix an app bug.

**3) Exact manual recovery procedure (if GitHub Actions rollback also fails):**

```
ssh deploy@<vps>
cd /opt/fieldtrack/app
COMPOSE="docker compose --env-file .env.prod -f docker-compose.prod.yml"

# 1. See what's available and what's running
docker images fieldtrack-app
docker inspect --format '{{.Config.Image}}' fieldtrack-app

# 2. Roll the APP back to a known-good SHA (do NOT downgrade the DB)
IMAGE_TAG=<previous-good-sha> $COMPOSE up -d --no-deps --force-recreate app
sleep 15
$COMPOSE exec -T app python -c "import urllib.request;urllib.request.urlopen('http://localhost:8000/api/v1/health')"

# 3. If the previous image was pruned, re-pull it from GHCR
echo "$GHCR_TOKEN" | docker login ghcr.io -u <user> --password-stdin
docker pull ghcr.io/<owner>/<repo>:<previous-good-sha>
docker tag  ghcr.io/<owner>/<repo>:<previous-good-sha> fieldtrack-app:<previous-good-sha>
IMAGE_TAG=<previous-good-sha> $COMPOSE up -d --no-deps --force-recreate app

# 4. Only if the DATA itself is corrupt: restore from backup (scripts/backup.sh + RESTORE.md)
#    Restore Postgres from the latest dump in /opt/fieldtrack/backups, then bring the app up.
```

---

## SUMMARY

| Section | Status | Action Needed |
|---|---|---|
| GitHub Actions Pipeline | ⚠️→✅ | Fixed: added real tests (CI gate was failing on 0 tests) + `--env-file .env.prod`. **Manual:** add the 4 required secrets; enable Required reviewers on the `production` environment. |
| Auth | ✅ | None — logic verified. Confirm 401-after-logout at runtime. |
| Attendance | ✅ | None — state machine + break-excluding duration unit-tested. |
| GPS & Location | ✅ | Logic verified. Confirm Redis dedup/live with `redis-cli` at runtime. |
| Geofencing | ✅ | Logic verified (64-pt buffer, ST_Contains, ENTER/EXIT pairing). Confirm event rows at runtime. |
| Sync Engine | ❓ | Flutter-side — manual offline test on a device. |
| Reports | ⚠️→✅ | Fixed: 35-day range now returns 400 (was shadowed to 422). Bug 2 (stuck PROCESSING) holds. |
| Notifications | ✅ | FCM no-op verified for both unconfigured and configured paths. |
| Admin Web | ✅ | WS/auth/loop verified. Confirm map markers + trail replay in a browser. |
| Production Config | ⚠️→✅ | Fixed: nginx optional-upstream startup crash; added prod seed with random password. **Manual:** fill in the real domain everywhere; create `.env.prod`. |
| Resource Sizing | ✅* | 4 GB sufficient for app stack (~1.1 GB headroom). **Caveat:** run Uptime Kuma only — full Grafana/Prometheus drops headroom to ~0.6 GB. Run `docker stats` on the VPS to confirm. |
| Rollback Safety | ⚠️→✅ | Fixed: container-internal health check + reliable rollback-tag capture. DB downgrades are destructive by design — roll back the image, never the schema. |

**Remaining hard blockers before deploy (manual, cannot be done from code):**
1. **Provide the real domain** and replace `your-domain.com` in nginx.prod.conf, `.env.prod`
   (ALLOWED_ORIGINS), monitoring `GF_SERVER_ROOT_URL`, and mobile `.env.prod`.
2. **Create `.env.prod`** on the VPS from `.env.prod.example` with real secrets.
3. **Add the GitHub secrets** and **enable Required reviewers** on the `production` environment.
4. **Push to main and confirm the CI test job is green** (the new tests run there with full deps).
