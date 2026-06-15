# FieldTrack — Database Restore Procedure

Use this if the production database is lost, corrupted, or you need to roll
back to a previous day's data (e.g. after a bad migration or data-entry
mistake).

**This is destructive** — it drops and recreates the database. Double-check
the backup file and the date before running step 4.

## 1. Stop the app (but NOT Postgres)

The app must not be writing while you restore. Postgres stays up so you can
connect to it.

```bash
cd /opt/fieldtrack/app
docker compose -f docker-compose.prod.yml stop app
```

## 2. Download the backup from Backblaze B2

```bash
# List available backups
b2 ls fieldtrack-backups daily/
b2 ls fieldtrack-backups weekly/

# Download the one you want (example: yesterday's daily backup)
b2 file download fieldtrack-backups daily/fieldtrack_2026-06-13.sql.gz \
    /opt/fieldtrack/backups/restore.sql.gz

gunzip /opt/fieldtrack/backups/restore.sql.gz
```

## 3. Drop and recreate the database

```bash
docker exec -it fieldtrack-postgres psql -U fieldtrack -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'fieldtrack';"

docker exec -it fieldtrack-postgres psql -U fieldtrack -d postgres -c \
    "DROP DATABASE fieldtrack;"

docker exec -it fieldtrack-postgres psql -U fieldtrack -d postgres -c \
    "CREATE DATABASE fieldtrack;"
```

## 4. Restore the dump

```bash
cat /opt/fieldtrack/backups/restore.sql | \
    docker exec -i fieldtrack-postgres psql -U fieldtrack -d fieldtrack
```

The dump from `pg_dump` includes the PostGIS extension and schema, so this
recreates everything — tables, indexes, geofence geometry columns.

## 5. Restart the app

```bash
docker compose -f docker-compose.prod.yml start app
sleep 15
curl -fsS http://localhost:8000/api/v1/health
```

## 6. Verify data integrity

- Log in to the admin dashboard and confirm employees/teams/geofences appear.
- Check the most recent attendance records match what you expect for the
  restored date (anything written AFTER the backup's timestamp is gone — this
  is expected for a point-in-time restore).
- Run `alembic current` inside the app container and compare against
  `alembic history` to confirm the restored schema version matches the
  current migration head. If the dump predates a migration that's since been
  applied, run `docker compose -f docker-compose.prod.yml run --rm app alembic upgrade head`.

## Why backups matter

A VPS is a single point of failure — disk corruption, an accidental `DROP
TABLE`, a bad migration, or the provider losing the box can all destroy data
instantly. Backups turn "data loss" into "lose at most 24 hours of data and
some downtime."

## What is Backblaze B2?

B2 is an S3-compatible object storage service, much cheaper than AWS S3 for
this kind of use (a few cents/GB/month). Backups are uploaded off the VPS so
that if the VPS itself is destroyed, the backups survive. `scripts/backup.sh`
keeps 7 days of daily backups and 4 weeks of weekly backups in B2.
