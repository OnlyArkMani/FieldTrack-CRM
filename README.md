# SamarthSathi CRM — Employee Tracking, Attendance & Field Sales System

<div align="center">

![SamarthSathi CRM](https://img.shields.io/badge/SamarthSathi%20CRM-Field%20Sales%20%26%20Tracking-F5A623?style=for-the-badge&logo=fastapi&logoColor=white)

**Production-grade employee tracking, attendance management, and field CRM — built for agricultural sales teams. Real-time GPS, polygon geofencing, offline-first sync, FCM notifications, farmer/customer database, visit planning, lead pipeline, and daily sales reporting — engineered for 15-100 employees on a single VPS without architecture changes.**

[![FastAPI](https://img.shields.io/badge/FastAPI-0.115-009688?style=flat-square&logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com/)
[![Python](https://img.shields.io/badge/Python-3.11-3776AB?style=flat-square&logo=python&logoColor=white)](https://www.python.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15-4169E1?style=flat-square&logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![PostGIS](https://img.shields.io/badge/PostGIS-3.4-4169E1?style=flat-square&logo=postgresql&logoColor=white)](https://postgis.net/)
[![Redis](https://img.shields.io/badge/Redis-7-DC382D?style=flat-square&logo=redis&logoColor=white)](https://redis.io/)
[![Flutter](https://img.shields.io/badge/Flutter-3.22-02569B?style=flat-square&logo=flutter&logoColor=white)](https://flutter.dev/)
[![React](https://img.shields.io/badge/React-18-61DAFB?style=flat-square&logo=react&logoColor=black)](https://reactjs.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?style=flat-square&logo=docker&logoColor=white)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-Proprietary-red.svg?style=flat-square)](LICENSE)

[Documentation](#documentation) | [Quick Start](#quick-start) | [API Reference](#api-endpoints) | [Architecture](#architecture) | [Deployment](#deployment)

**GitHub:** https://github.com/OnlyArkMani/SamarthSathi-CRM

</div>

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [CRM Extension Modules](#crm-extension-modules)
- [Technology Stack](#technology-stack)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [API Endpoints](#api-endpoints)
- [Deployment](#deployment)
- [Documentation](#documentation)
- [Project Structure](#project-structure)
- [Roadmap](#roadmap)

---

## Overview

**SamarthSathi CRM** is a full-stack, production-grade system combining employee attendance tracking with a field sales CRM — purpose-built for agricultural sales teams. It ships a FastAPI backend with async PostgreSQL and Redis, a Flutter mobile app with offline-first architecture, and a React admin dashboard with real-time WebSocket updates.

The core tracking layer handles attendance, GPS, geofencing, and reporting. The CRM layer adds a farmer/customer database, pre-day visit planning, in-field visit execution with livestock profiles and order capture, a Hot/Warm/Cold lead pipeline, and auto-generated Daily Sales Reports (DSR) on attendance end.

All of this runs containerised on a single 2 vCPU / 4 GB RAM VPS with zero architecture changes needed to scale from 15 to 100 employees.

---

## Key Features

### Attendance State Machine

- 4-state workflow: START → BREAK → RESUME → END
- Work summary notes on end-of-day
- Daily reminders (9 AM clock-in, 6 PM clock-out)
- Session tracking with millisecond precision for compliance
- DSR auto-generated when employee submits END attendance

### Real-Time GPS Tracking

- Live location updates every 5 minutes, flat, while on duty (moving or stationary)
- Battery-aware exception: interval widens to 20 minutes when the device drops below 20% battery
- Mock GPS flagged (not hard-blocked), visible to admin
- Offline tile caching via OpenStreetMap — maps work without internet
- Sync-lag metrics from device capture time vs. server arrival timestamp
- Configurable GPS interval per team (admin-controlled, Module 6)

### Geofencing and Polygon Detection

- Polygon geofencing (not circles) via PostGIS ST_Contains()
- Automatic zone entry/exit detection with GIST spatial index
- Event logging for compliance audits
- Distance and time-in-zone analytics in reports

### Push Notifications (Firebase Cloud Messaging)

- Attendance reminders (clock-in/out prompts)
- GPS alerts (zone entry/exit, low battery, no internet)
- Admin announcements broadcast to all employees
- Scheduled delivery respecting business hours

### Reports and Analytics

- CSV, Excel, PDF exports with configurable date ranges
- Attendance summaries by employee, team, and date
- Distance and zone-time analytics
- Async generation with polling and auto-cleanup

### Offline-First Architecture

- Local SQLite queue on mobile with hybrid sync cadence
- Deduplication via Redis (6-hour window) prevents duplicate processing
- Async validation — failed syncs retry without blocking the UI
- Conflict resolution for offline changes vs. server updates

### Role-Based Access Control

- Admin (web-only) — full control, user management, reports, dashboards, CRM oversight
- Manager (mobile + web read) — team-scoped view, attendance, CRM pipeline
- Employee (mobile) — attendance, GPS, farmer visits, leads, DSR

### Dark and Light Theme

- System theme toggle from the Profiles tab (persistent across sessions)
- Warm color palette (Amber primary, Soft Purple secondary)
- Smooth 350ms transitions across all screens

---

## CRM Extension Modules

### Module 1 — Farmer / Customer Database

Central farmer/customer entity with contact details, village/district, GPS coordinates (set on first visit), cattle count, current feed brand and price, and team assignment. All field users see their team's farmers; admin sees all.

### Module 2 — Visit Planning (Pre-Day)

Employees plan their field visits the day before: select target farmers, estimated visit time, and purpose. Managers can view their team's pending plans and flag missing submissions. Plans feed directly into Module 3 execution.

### Module 3 — Field Visit Execution

On-field visit flow:

- **Check-in** with GPS location — warning + remark if outside farmer's expected location (no hard block)
- **Meeting notes** — structured or free-text notes during the visit
- **Livestock profile** — cattle count, feed consumption, health observations, product interest
- **Order capture** — product selection, quantity, price per bag, total (manager approval deferred to v2)
- **Complete visit** — status set, duration recorded, lead tag updated

### Module 4 — Lead Management (Hot / Warm / Cold)

Every farmer carries a lead status. Field employees update it during or after a visit. Managers see the full team pipeline with counts by status. Follow-ups can be scheduled with a target date and notes. Admin views the org-wide pipeline with filters.

### Module 5 — Daily Sales Report (DSR)

Auto-generated when an employee submits END attendance. The DSR captures: total visits completed, farmers met, orders placed, lead status changes, total order value, and end-of-day notes. Managers and admin can add manager comments. DSRs are archived by date and exportable.

### Module 6 — Configurable GPS Interval

Admins set per-team GPS reporting intervals (moving cadence and stationary cadence) from the dashboard. Settings are Redis-cached (24h TTL) and pulled by mobile on next sync. Overrides global defaults without a code deploy.

---

## Technology Stack

### Backend

| Component        | Version      | Purpose                                                   |
| ---------------- | ------------ | --------------------------------------------------------- |
| FastAPI          | 0.115+       | Async web framework with auto-generated OpenAPI docs      |
| Python           | 3.11+        | Async throughout via asyncpg + SQLAlchemy 2.0             |
| PostgreSQL       | 15 + PostGIS | Spatial queries for geofencing; async via asyncpg         |
| Redis            | 7            | Cache, session management, sync deduplication, GPS config |
| APScheduler      | 3.11+        | In-process job scheduler (no Celery dependency)           |
| Alembic          | 1.15+        | Database migrations with async support                    |
| PyJWT            | 2.10+        | JWT token handling with separate access/refresh secrets   |
| Passlib + Bcrypt | 1.7.4        | Password hashing (12 rounds)                              |

### Frontend (Admin Web)

| Component    | Version | Purpose                          |
| ------------ | ------- | -------------------------------- |
| React        | 18.3+   | UI framework for admin dashboard |
| Vite         | 5.3+    | Fast build tool and dev server   |
| Tailwind CSS | 3.4+    | Utility-first CSS framework      |
| Zustand      | 4.5+    | Lightweight state management     |
| React Router | 6.24+   | Client-side routing              |
| Axios        | 1.7+    | HTTP client with interceptors    |
| React Query  | 5.51+   | Data fetching and caching        |
| Recharts     | 2.12+   | Charts and data visualizations   |
| Leaflet      | 1.9+    | Interactive mapping library      |

### Mobile (Flutter)

| Component                | Version | Purpose                                         |
| ------------------------ | ------- | ----------------------------------------------- |
| Flutter                  | 3.22+   | Cross-platform development (Android min SDK 21) |
| Riverpod                 | 2.6+    | App-wide state management                       |
| GoRouter                 | 14.8+   | Type-safe routing with deep linking             |
| flutter_map              | 7.0+    | OpenStreetMap rendering                         |
| flutter_map_tile_caching | 9.1+    | Offline map tile storage                        |
| geolocator               | 13.0+   | GPS location services                           |
| background_locator_2     | 2.0+    | Background location tracking                    |
| Firebase Messaging       | 15.2+   | Push notifications (FCM)                        |
| Dio                      | 5.8+    | HTTP client with retry logic                    |
| sqflite                  | 2.4+    | Local SQLite database for offline queue         |

### Deployment Infrastructure

| Component            | Purpose                                       |
| -------------------- | --------------------------------------------- |
| Docker               | Container runtime and orchestration           |
| Docker Compose       | Multi-service deployment definition           |
| Nginx                | Reverse proxy, rate limiting, TLS termination |
| Gunicorn + Uvicorn   | ASGI server with worker process management    |
| Prometheus + Grafana | Metrics collection and visualization          |
| Uptime Kuma          | Uptime monitoring and status page             |

---

## Quick Start

### Prerequisites

- Docker and Docker Compose v2.0 or later
- Git
- For local development: Python 3.11+, Node.js 18+, Flutter 3.22+

### Local Development Setup

```bash
# 1. Clone the repo
git clone https://github.com/OnlyArkMani/SamarthSathi-CRM.git
cd SamarthSathi-CRM

# 2. Create environment file
cp .env.example .env
# Fill in secrets (see Configuration below)

# 3. Start all services (postgres, redis, app, nginx)
docker compose up -d --build

# 4. Run migrations
docker compose exec app alembic upgrade head

# 5. Check health
curl http://localhost:8090/api/v1/health
# {"status":"ok","env":"development"}

# 6. Open dashboard
# Admin web: http://localhost:8090
# API docs:  http://localhost:8090/api/v1/docs
```

---

## Configuration

### Environment Variables

**Database**

```env
DATABASE_URL=postgresql+asyncpg://fieldtrack:PASSWORD@postgres:5432/fieldtrack
DB_POOL_SIZE=10           # Raise to 20+ at 100 employees
DB_MAX_OVERFLOW=5
```

**Redis**

```env
REDIS_URL=redis://:PASSWORD@redis:6379/0
```

**JWT & Auth**

```env
JWT_ACCESS_SECRET=<openssl rand -hex 32>
JWT_REFRESH_SECRET=<openssl rand -hex 32>   # DIFFERENT from access
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=7
```

**Firebase Cloud Messaging (FCM)**

```env
FCM_SERVICE_ACCOUNT_FILE=/run/secrets/fcm-service-account.json
FCM_PROJECT_ID=your-firebase-project-id
```

> **FCM Setup:** Download the service account JSON from Firebase Console → Project Settings → Service Accounts → Generate New Private Key. Place `google-services.json` at `mobile/android/app/google-services.json` before building the Flutter APK — this file is excluded from git.

**Reports**

```env
REPORT_STORAGE_DIR=/srv/fieldtrack/reports
REPORT_RETENTION_MINUTES=60
```

**App & Server**

```env
APP_ENV=development
DEBUG=true                  # MUST be false in prod
NGINX_HTTP_PORT=8090        # 8080/8081 unavailable
UVICORN_WORKERS=2           # Match vCPU count
```

See `.env.example` for all options.

---

## Architecture

### Async Throughout

- FastAPI + asyncpg + SQLAlchemy 2.0 — async/await everywhere
- Zero blocking I/O on critical paths (location pings, sync batches, visit saves)
- Scales to 100 employees on 2 vCPU without Celery or message brokers

### Database Design (23 Tables)

**Core tracking:** `users`, `teams`, `attendance`, `attendance_sessions`, `location_logs`, `geofences`, `geofence_events`, `notifications`, `sync_queue`, `device_info`, `audit_logs`, `settings`

**CRM extension:** `farmers`, `visit_plans`, `visit_plan_items`, `visits`, `visit_notes`, `livestock_profiles`, `visit_orders`, `leads`, `follow_ups`, `daily_reports`, `gps_config`

Key decisions: PostGIS for spatial queries, partial indexes on hot paths, native Postgres enums for domain states, timestamptz everywhere (UTC server, clients localize).

### Redis Strategy

- Never source of truth — every key is reconstructible from Postgres
- Every key has a TTL — volatile-lru eviction, graceful degradation
- Refresh tokens stored as sha256 hashes (never raw credentials)
- Sync deduplication via atomic SET NX
- GPS config cached per team (24h TTL)

### Security

- JWT with separate access (15 min) + refresh (7 day) secrets
- Refresh token rotation with session theft detection
- Rate limiting: 30 req/s per IP (Nginx) + per-endpoint limits (app)
- Bcrypt password hashing (12 rounds)
- Non-root Docker — runs as `app:app`
- Audit trail for login, attendance changes, role changes

---

## API Endpoints

### Authentication

- `POST /api/v1/auth/login` — Get access + refresh tokens
- `POST /api/v1/auth/refresh` — Rotate access token
- `POST /api/v1/auth/logout` — Revoke tokens
- `POST /api/v1/auth/forgot-password` / `reset-password`
- `GET  /api/v1/auth/me` — Current user profile

### Employees & Teams

- `GET/POST /api/v1/employees` — List / create employees
- `GET/PUT  /api/v1/employees/{id}` — Get / update employee
- `GET/POST /api/v1/teams` — List / create teams
- `PUT      /api/v1/teams/{id}` — Update team assignment

### Attendance

- `POST /api/v1/attendance/start` — Begin work day
- `POST /api/v1/attendance/break` — Begin break
- `POST /api/v1/attendance/resume` — Resume after break
- `POST /api/v1/attendance/end` — End work day (triggers DSR auto-generation)
- `GET  /api/v1/attendance/today` — Current session state
- `GET  /api/v1/attendance/history` — Historical records

### Location & Geofencing

- `POST /api/v1/location/batch` — Submit GPS pings (mobile)
- `GET  /api/v1/location/live/{user_id}` — Last known position
- `GET  /api/v1/location/team-live` — All employees' current position (admin)
- `POST /api/v1/geofences` — Create zone polygon
- `GET  /api/v1/geofences` — List all zones
- `GET  /api/v1/geofences/{id}/events` — Zone entry/exit log

### CRM — Farmers (Module 1)

- `GET/POST /api/v1/farmers` — List (team-scoped) / create farmer
- `GET/PUT  /api/v1/farmers/{id}` — Get / update farmer
- `GET      /api/v1/farmers/{id}/visits` — Farmer visit history
- `GET      /api/v1/farmers/{id}/lead` — Current lead status

### CRM — Visit Planning (Module 2)

- `GET/POST /api/v1/visit-plans/my` — Get or create today's plan
- `PATCH    /api/v1/visit-plans/my/items/{id}` — Update plan item status
- `GET      /api/v1/visit-plans/team` — Manager: team plans
- `GET      /api/v1/visit-plans/pending-submissions` — Manager: missing plans

### CRM — Field Visits (Module 3)

- `POST /api/v1/visits/check-in` — Start visit with GPS location
- `GET  /api/v1/visits/active` — Current open visit
- `PUT  /api/v1/visits/{id}/notes` — Upsert meeting notes
- `PUT  /api/v1/visits/{id}/livestock` — Upsert livestock profile
- `POST /api/v1/visits/{id}/orders` — Add order to visit
- `POST /api/v1/visits/{id}/complete` — Complete visit

### CRM — Leads (Module 4)

- `GET /api/v1/leads` — Lead pipeline (team-scoped)
- `PUT /api/v1/leads/{farmer_id}` — Update lead status (Hot/Warm/Cold)
- `GET /api/v1/leads/pipeline` — Pipeline summary with counts
- `GET /api/v1/leads/team/{team_id}` — Manager: team lead view
- `POST    /api/v1/follow-ups` — Schedule follow-up
- `GET/PUT /api/v1/follow-ups/{id}` — Get / update follow-up

### CRM — Daily Sales Report (Module 5)

- `GET  /api/v1/daily-reports/my` — Employee's own DSRs
- `GET  /api/v1/daily-reports/team` — Manager: team DSRs
- `GET  /api/v1/daily-reports/{id}` — Full DSR with visit breakdown
- `POST /api/v1/daily-reports/{id}/comment` — Manager comment
- `GET  /api/v1/daily-reports/archive` — Date-range archive

### GPS Config (Module 6)

- `GET /api/v1/gps-config/my` — Employee: get team's GPS interval config
- `GET /api/v1/gps-config/team/{team_id}` — Admin/manager view
- `PUT /api/v1/gps-config/team/{team_id}` — Admin: update interval (Redis-cached)

### Reports & Exports

- `POST /api/v1/reports/generate` — Async export (CSV/Excel/PDF)
- `GET  /api/v1/reports/{id}/status` — Poll generation status
- `GET  /api/v1/reports/{id}/download` — Download export file

### Sync & Notifications

- `POST /api/v1/sync/attendance-sessions` — Submit offline attendance batch
- `GET  /api/v1/sync/status` — Sync queue status
- `POST /api/v1/notifications/broadcast` — Admin announcement
- `POST /api/v1/devices/token` — Register FCM token

### WebSocket

- `WS /api/v1/ws/admin-live` — Real-time employee location stream (admin only, 15s heartbeat)

Full schema at `http://localhost:8090/api/v1/docs` (Swagger UI).

---

## Project Structure

```
SamarthSathi-CRM/
├── app/                               # FastAPI backend
│   ├── main.py                        # Entry point, route registration
│   ├── core/                          # Infrastructure (config, security, db, redis)
│   ├── api/v1/                        # HTTP routes (zero business logic)
│   │   ├── auth.py
│   │   ├── attendance.py
│   │   ├── employees.py
│   │   ├── teams.py
│   │   ├── location.py
│   │   ├── geofencing.py
│   │   ├── notifications.py
│   │   ├── reports.py
│   │   ├── sync.py
│   │   ├── ws.py
│   │   ├── farmers.py                 # Module 1
│   │   ├── visit_plans.py             # Module 2
│   │   ├── visits.py                  # Module 3
│   │   ├── leads.py                   # Module 4
│   │   ├── follow_ups.py              # Module 4
│   │   ├── daily_reports.py           # Module 5
│   │   └── gps_config.py              # Module 6
│   ├── services/
│   │   ├── attendance.py
│   │   ├── location.py
│   │   ├── reports.py
│   │   ├── notification.py
│   │   ├── farmer_service.py
│   │   ├── visit_plan_service.py
│   │   ├── visit_service.py
│   │   ├── lead_service.py
│   │   └── dsr_service.py
│   ├── models/
│   │   ├── user.py
│   │   ├── attendance.py
│   │   ├── location.py
│   │   ├── geofence.py
│   │   ├── misc.py
│   │   ├── enums.py
│   │   └── crm.py                     # All 11 CRM tables
│   └── schemas/
│
├── admin-web/src/features/
│   ├── dashboard/
│   ├── employees/
│   ├── attendance/
│   ├── map/
│   ├── reports/
│   ├── geofences/
│   ├── teams/
│   ├── settings/
│   ├── farmers/                       # Module 1
│   ├── planning/                      # Module 2
│   ├── leads/                         # Module 4
│   ├── followups/                     # Module 4
│   └── daily-reports/                 # Module 5
│
├── mobile/lib/features/
│   ├── attendance/
│   ├── dashboard/
│   ├── map/
│   ├── notifications/
│   ├── profile/
│   ├── reports/
│   └── crm/
│       ├── farmers/                   # Module 1
│       ├── planning/                  # Module 2
│       ├── visits/                    # Module 3
│       ├── leads/                     # Module 4
│       ├── followups/                 # Module 4
│       └── dsr/                       # Module 5
│
├── alembic/versions/
│   ├── 0001_initial_schema.py         # Core tables
│   ├── 0002_geofence_shapes.py
│   ├── 0003_team_is_active.py
│   ├── 0004_audit_logs.py
│   └── 0005_crm_tables.py             # 11 CRM tables
│
├── nginx/
├── monitoring/
├── scripts/
├── tests/
├── docs/REDIS_KEYS.md
├── docker-compose.yml
├── docker-compose.prod.yml
├── Dockerfile
└── .env.example
```

---

## Deployment

### Infrastructure Requirements

**VPS:** 2 vCPU, 4 GB RAM, Ubuntu 22.04 LTS

**Resource Allocation:**

```
PostgreSQL:     1 GB
Redis:          256 MB
FastAPI App:    1 GB (2x Uvicorn workers)
Nginx:          128 MB
────────────────────
Total Used:     ~2.4 GB
Headroom:       ~1.6 GB
```

**Deploy:**

```bash
git clone https://github.com/OnlyArkMani/SamarthSathi-CRM.git /opt/fieldtrack/app
cp .env.prod.example .env.prod   # Fill real secrets
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml exec app alembic upgrade head
./scripts/ssl_setup.sh your-domain.com
```

See `DEPLOYMENT_CHECKLIST.md` for the complete step-by-step guide.

---

## Documentation

- **ARCHITECTURE.md** — Design decisions and reasoning
- **DEPLOYMENT_CHECKLIST.md** — Step-by-step production deployment with verification
- **RESTORE.md** — Backup restoration and disaster recovery
- **docs/REDIS_KEYS.md** — Complete Redis key schema, TTLs, and memory budget
- **API Docs** — Auto-generated Swagger UI at `/api/v1/docs` (dev/staging only)

---

## Roadmap

### Completed

- Attendance state machine (START/BREAK/RESUME/END) with work summary
- Real-time GPS tracking on a flat 5-minute cadence, with a battery-saving exception
- Polygon geofencing via PostGIS — team-scoped zone assignment with entry/exit events
- Offline-first mobile sync with Redis deduplication
- CSV, Excel, PDF report export — async pipeline, auto-prune after retention
- Push notifications via FCM — reminders, GPS alerts, admin broadcast
- Admin live dashboard with WebSocket real-time updates
- 31-day employee location trail with replay on admin map
- Dark/light theme toggle
- Android build: AGP 8.11.1, Gradle 8.14, Kotlin 2.2.20
- GitHub Actions CI/CD pipeline
- **CRM Module 1** — Farmer/customer database with team scoping
- **CRM Module 2** — Pre-day visit planning with manager oversight
- **CRM Module 3** — Field visit execution with check-in, notes, livestock profile, order capture
- **CRM Module 4** — Hot/Warm/Cold lead pipeline with follow-up scheduling
- **CRM Module 5** — Daily Sales Report auto-generated on attendance END
- **CRM Module 6** — Per-team configurable GPS intervals (admin-controlled, Redis-cached)

### Planned

- Manager approval workflow for field orders
- Payroll system integration
- WhatsApp/SMS notifications (supplementing FCM)
- Multi-language support
- iOS mobile app
- Offline DSR draft support

---

**Project Status:** Production Ready
**Last Updated:** June 30, 2026
**Current Version:** 0.3.0
**Repository:** https://github.com/OnlyArkMani/SamarthSathi-CRM
