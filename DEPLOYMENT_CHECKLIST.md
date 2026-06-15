# FieldTrack Production Deployment Checklist

Copy this into a tracking issue/doc and check items off as you go.

## Infrastructure

- [ ] VPS provisioned (2 vCPU / 4 GB RAM, Ubuntu 22.04)
- [ ] DNS A record for `your-domain.com` (and `www`) points at the VPS IP
- [ ] `scripts/server_setup.sh` run as root on the VPS
- [ ] `deploy` user can SSH in with a dedicated keypair (not your personal key)
- [ ] UFW shows only 22/80/443 open (`ufw status`)
- [ ] fail2ban running (`systemctl status fail2ban`)
- [ ] Repo cloned to `/opt/fieldtrack/app`

## SSL & Security

- [ ] `.env.prod` created on the VPS from `.env.prod.example` with real secrets
      (`openssl rand -hex 32` for each JWT secret, strong DB/Redis passwords)
- [ ] `scripts/ssl_setup.sh your-domain.com` run successfully
- [ ] `nginx/nginx.prod.conf` — every `your-domain.com` placeholder replaced
      with the real domain
- [ ] `certbot renew --dry-run` passes; renewal cron entry present
      (`crontab -l`)
- [ ] SSL Labs test (`https://www.ssllabs.com/ssltest/`) scores A or higher

## Application

- [ ] `docker compose -f docker-compose.prod.yml up -d` brings up
      postgres/redis/app/nginx healthy (`docker compose ps`)
- [ ] `alembic upgrade head` run inside the app container — schema is current
- [ ] `curl https://your-domain.com/api/v1/health` returns `{"status":"ok"}`
- [ ] Admin login works at `https://your-domain.com`
- [ ] PostGIS extension present (`SELECT postgis_version();` in psql)
- [ ] FCM service account JSON present at the path in `FCM_SERVICE_ACCOUNT_FILE`
- [ ] `FCM_PROJECT_ID` matches the Firebase project used by the mobile app

## Mobile

- [ ] `mobile/.env.prod` created from `.env.prod.example` with the real domain
- [ ] `mobile/android/app/google-services.json` is the PRODUCTION Firebase config
      (not the dev/staging one)
- [ ] `scripts/build_flutter.sh` produces split APKs (`arm64-v8a`, `armeabi-v7a`, `x86_64`)
- [ ] Installed on at least one real low-end Android device (min SDK 21)
- [ ] **Offline sync test**: enable airplane mode, record attendance/GPS for
      a few minutes, disable airplane mode, confirm data syncs to the server
- [ ] **FCM test**: trigger an attendance reminder / admin announcement and
      confirm it's received on the real device
- [ ] Background GPS tracking survives the app being backgrounded/killed
- [ ] Offline map tiles load with no internet connection

## Monitoring

- [ ] `monitoring/docker-compose.monitoring.yml` stack started
- [ ] Uptime Kuma monitor created for `/api/v1/health`, status page at `/status`
- [ ] Grafana admin password changed from default
- [ ] Prometheus + node-exporter data source connected in Grafana
- [ ] FastAPI + Node Exporter dashboards imported
- [ ] Alerts configured: response time > 2s, error rate > 5%, disk usage > 80%
- [ ] Email (or other) contact point configured and tested

## Final

- [ ] `scripts/backup.sh` runs successfully manually, file appears in B2
- [ ] Backup cron entry present (`0 2 * * * .../backup.sh`)
- [ ] `RESTORE.md` procedure tested at least once (e.g. against a staging DB)
- [ ] GitHub Secrets all set: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`,
      `GHCR_TOKEN`, `NOTIFY_WEBHOOK_URL`, `CODECOV_TOKEN`
- [ ] `production` GitHub Environment configured with required reviewers
- [ ] A test push to `main` runs through test -> build -> deploy successfully
- [ ] Deploy notification arrives in Discord/Slack
- [ ] Admin web (`scripts/build_admin.sh`) deployed and reachable

---

## Troubleshooting

**Container won't start**
```bash
docker compose -f docker-compose.prod.yml logs <service> --tail 100
```
Most common causes: missing/incorrect value in `.env.prod` (the container
exits immediately if a required setting is missing), or a port conflict
(`docker compose ps` shows "unhealthy" if the healthcheck command itself is
wrong — check the healthcheck's exact command runs inside the container).

**Migrations failed / need to roll back**
```bash
# See current and available revisions
docker compose -f docker-compose.prod.yml run --rm app alembic current
docker compose -f docker-compose.prod.yml run --rm app alembic history

# Roll back one revision
docker compose -f docker-compose.prod.yml run --rm app alembic downgrade -1
```
If a migration partially applied and `upgrade head` now fails, restore from
the most recent backup (see `RESTORE.md`) rather than hand-editing the schema
— PostGIS geometry columns are easy to get into an inconsistent state by
editing manually.

**Health check failing after deploy**
1. `docker compose -f docker-compose.prod.yml logs app --tail 50` — look for
   a startup exception (bad env var, DB connection refused, Redis auth
   failure).
2. `docker compose -f docker-compose.prod.yml exec app python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/api/v1/health').read())"`
   — run the healthcheck command manually to see the real error.
3. If the deploy workflow already rolled back automatically, check which
   image tag is running: `docker ps --format '{{.Image}}'`.

**GPS not showing on the admin map**
- Confirm the mobile device actually has location permission + "GPS Disabled"
  isn't shown in the live dashboard status.
- Check Redis for recent location keys:
  `docker exec -it fieldtrack-redis redis-cli -a $REDIS_PASSWORD --scan --pattern 'location:*'`
- If keys exist but the map doesn't update, check the admin SPA's WebSocket
  connection in the browser devtools (Network -> WS) — `/api/v1/ws/admin-live`
  should show status 101 (switching protocols), not a 4xx/connection error.

**FCM not delivering**
- Firebase console -> Cloud Messaging -> check delivery reports for the
  message.
- Verify `FCM_SERVICE_ACCOUNT_FILE` points to a valid, non-expired service
  account JSON for the correct project (`FCM_PROJECT_ID`).
- Confirm the device's FCM token was actually registered (`device_info`
  table) — a stale/uninstalled-app token returns
  `UNREGISTERED` from FCM, which is expected and not a config bug.
