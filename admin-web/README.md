# FieldTrack Admin (web)

The **web-only** admin dashboard for FieldTrack. Admins manage employees,
teams, attendance, live tracking and reports here — they do **not** use the
mobile app.

Stack: **React 18 + Vite + TailwindCSS**, React Query (server state), Zustand
(auth + UI), React Router, Leaflet (live map), Recharts (charts).

## Design system

The same FieldTrack palette as the Flutter app, expressed as CSS variables in
`src/index.css` and surfaced through Tailwind tokens (`tailwind.config.js`):
cream `#FFF8E7`, amber `#F5A623`, soft purple `#8B7FD4`, coral `#E8645A`,
midnight `#1A1A2E`. Inter font, 12px card radius, dark/light toggle (the
`.dark` class on `<html>` flips every token).

## Run

```bash
cd admin-web
cp .env.example .env        # adjust VITE_PROXY_TARGET if the API isn't on :8000
npm install
npm run dev                 # http://localhost:5173 (proxies /api → backend)
```

The Vite dev server proxies `/api` (and the `/ws` upgrade) to the FastAPI
backend so the SPA and API share an origin — required because the refresh
token is an httpOnly cookie scoped to `/api/v1/auth`.

Build for production with `npm run build` (output in `dist/`); serve it behind
the same Nginx as the API.

## Auth

Login posts `client: "web"`, so the backend returns the access token in the
body (kept in memory only) and the refresh token as an httpOnly cookie. On page
load the app calls `/auth/refresh` to restore the session; the axios
interceptor refreshes transparently on 401. The dashboard is **admin-only** —
non-admins are shown an "admins only" notice.

## Live updates

The dashboard's live table uses React Query polling (30s). The **Live Map**
uses the WebSocket feed `WS /api/v1/ws/admin-live?token=…` (`useWebSocket.js`),
which pushes a fresh snapshot every 15s and immediately whenever any device
reports a new position (Redis pub/sub on the backend).

## Structure

```
src/
  components/ui/      Button, Card, Badge, Table, Modal, Input, Sidebar, …
  components/layout/  AppLayout, Topbar
  features/
    auth/ dashboard/ employees/ teams/ attendance/ map/ reports/ settings/
  hooks/              useEmployees, useTeams, useAttendance, useDashboard,
                      useWebSocket, useGlobalSearch
  services/api/       axios instance + auth/refresh interceptor
  store/              authStore, uiStore (Zustand)
  lib/                queryClient
```
