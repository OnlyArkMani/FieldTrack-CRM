# FieldTrack — Test & Run Runbook (CRM extension)

Covers rebuilding Docker, running migrations, backend tests, CRM endpoint smoke-tests,
the admin web dashboard, and the Flutter app.

**Your actual ports (from `.env`):**

| Service  | Host port | URL / access                     |
|----------|-----------|----------------------------------|
| Nginx    | **8090**  | http://localhost:8090            |
| Postgres | **5434**  | localhost:5434 (internal 5432)   |
| Redis    | **6380**  | localhost:6380 (internal 6379)   |
| App      | 8000      | internal only (behind Nginx)     |

Run everything from the repo root: `C:\Projects\SamarthAgri\FieldTrack\FieldTrack`

> **Image is prod-only.** The Docker image copies just `app/` + `alembic/`.
> `scripts/` and `tests/` are **not** inside the container, so any
> `docker compose exec app python scripts/...` fails with "No such file or
> directory". Sections 3 and 5 below use the correct workarounds.

---

## 1. Update / rebuild the Docker containers

```bash
# Rebuild the app image with the new CRM code and restart the stack
docker compose up -d --build

# Clean rebuild (no cache) if needed:
docker compose build --no-cache app
docker compose up -d

# Confirm all 4 containers are healthy
docker compose ps
```

Expected: `fieldtrack-postgres`, `fieldtrack-redis`, `fieldtrack-app`, `fieldtrack-nginx`
all `Up (healthy)`. Tail logs if not:

```bash
docker compose logs -f app
```

---

## 2. Run the CRM migrations

CRM tables ship in `0005_fieldcrm_schema` and `0006_dsr_manager_comment`.

```bash
docker compose exec app alembic upgrade head     # idempotent
docker compose exec app alembic current          # should show 0006

# Verify the new tables exist
docker compose exec postgres psql -U fieldtrack -d fieldtrack -c "\dt" | \
  grep -E "farmers|visits|visit_notes|livestock_profiles|visit_orders|leads|follow_ups|daily_reports|visit_plans|gps_config"
```

---

## 3. Seed test users

`scripts/` isn't in the image, so pipe the script into the container's python
(it only imports `app.*`, which IS in the image):

```bash
docker compose exec -T app python - < scripts/seed_users.py
```

| Role       | Email                      | Password       |
|------------|----------------------------|----------------|
| Admin      | admin@fieldtrack.com       | Admin@123      |
| Supervisor | supervisor@fieldtrack.com  | Super@123      |
| Employee   | employee@fieldtrack.com    | Employee@123   |

---

## 4. Health check

```bash
curl http://localhost:8090/api/v1/health
# {"status":"ok","env":"development"}
```

Interactive API docs (try every CRM endpoint): **http://localhost:8090/api/v1/docs**

---

## 5. Backend automated tests

pytest is installed in the image, but the `tests/` folder is not copied in. Copy it
into the running container first, then run:

```bash
docker compose cp tests app:/srv/fieldtrack/tests
docker compose cp pytest.ini app:/srv/fieldtrack/pytest.ini
docker compose exec app pytest -v -p no:cacheprovider
```

`-p no:cacheprovider` avoids a cache-write permission error (app runs as non-root).

Alternative — run locally with the venv (needs DB reachable at localhost:5434):

```bash
#   Windows:  venv\Scripts\activate
#   then:     pytest -v
```

> Note: the automated suite is currently `tests/test_core_logic.py` only. There are
> no dedicated CRM (farmer/visit/lead/DSR) API tests yet — use the smoke-tests in
> section 6 to exercise those modules.

---

## 6. CRM endpoint smoke-tests

Grab an admin token, then hit each new module. (Uses `jq`; drop the pipe if you don't have it.)

```bash
# 6.1 Login → capture access token
TOKEN=$(curl -s http://localhost:8090/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@fieldtrack.com","password":"Admin@123"}' | jq -r .access_token)
echo "$TOKEN"

AUTH="Authorization: Bearer $TOKEN"

# 6.2 Module 1 — Farmers (customer/farmer DB)
curl -s -H "$AUTH" http://localhost:8090/api/v1/farmers | jq
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  http://localhost:8090/api/v1/farmers \
  -d '{"name":"Ramesh Patel","phone":"9812345678","village":"Anand"}' | jq

# 6.3 Module 2 — Visit Plans (pre-day planning)
curl -s -H "$AUTH" http://localhost:8090/api/v1/visit-plans | jq

# 6.4 Module 3 — Visits (execution + notes + livestock)
curl -s -H "$AUTH" http://localhost:8090/api/v1/visits | jq

# 6.5 Module 4 — Leads (Hot / Warm / Cold) + follow-ups
curl -s -H "$AUTH" http://localhost:8090/api/v1/leads | jq
curl -s -H "$AUTH" http://localhost:8090/api/v1/follow-ups | jq

# 6.6 Module 5 — Daily Sales Report (DSR)
curl -s -H "$AUTH" http://localhost:8090/api/v1/daily-reports | jq

# 6.7 Module 6 — GPS config (admin per-team interval)
curl -s -H "$AUTH" http://localhost:8090/api/v1/gps-config | jq
```

Each should return `200` (a list, or the created object for POSTs). `401` = token didn't
attach; `404` = routing/migration off; `500` = check `docker compose logs -f app`.

---

## 7. Admin web dashboard (React + Vite)

```bash
cd admin-web
npm install            # first run only

# Option A — dev server (hot reload, proxies /api → http://localhost:8090)
npm run dev
#   → http://localhost:5173   (log in as admin@fieldtrack.com)

# Option B — production build served through Nginx at :8090
npm run build          # or: bash scripts/build_admin.sh
```

The dev proxy forwards `/api` and the `/api/v1/ws` WebSocket to `:8090`, so the live
dashboard and CRM screens talk to the running backend automatically.

---

## 8. Flutter mobile app

```bash
cd mobile
flutter pub get
flutter devices                 # list devices / emulators
flutter run                     # debug on connected device/emulator
flutter build apk --release     # or: bash scripts/build_flutter.sh
```

**Backend URL for the app:**
- Android **emulator** → `http://10.0.2.2:8090`
- **Physical phone** on same Wi-Fi → `http://<your-laptop-LAN-IP>:8090` (not `localhost`)

> FCM push needs `mobile/android/app/google-services.json` in place before building
> (excluded from git). Without it, attendance reminders / GPS alerts won't fire, but
> the rest of the app runs fine.

---

## 9. Quick teardown / reset

```bash
docker compose down        # stop everything
docker compose down -v     # also WIPE the DB (re-run migrations + seed after)
```

---

### One-shot "test everything" sequence

```bash
docker compose up -d --build
docker compose exec app alembic upgrade head
docker compose exec -T app python - < scripts/seed_users.py
curl http://localhost:8090/api/v1/health
docker compose cp tests app:/srv/fieldtrack/tests
docker compose cp pytest.ini app:/srv/fieldtrack/pytest.ini
docker compose exec app pytest -v -p no:cacheprovider
# then run section 6 smoke-tests, section 7 admin web, section 8 mobile
```
