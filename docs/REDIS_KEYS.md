# FieldTrack — Redis Key Schema

Single source of truth for every Redis key the system uses. The code mirror of
this document is `app/core/redis.py` (`Keys` class) — keep both in sync.

All keys are prefixed `fieldtrack:` so this Redis instance could be shared in
an emergency without collisions (it shouldn't be, but namespacing is free).

Eviction policy is `volatile-lru` with `maxmemory 200mb` (set in
docker-compose.yml): only keys **with** a TTL are evictable, and every key
below has one — so Redis degrades gracefully under memory pressure instead of
OOM-ing, and nothing here is "load-bearing forever" state. **Postgres is
always the source of truth; Redis is cache + coordination.** Any key being
lost is recoverable (worst case: one duplicate sync batch is re-validated
against DB constraints).

---

## 1. Live employee location

```
Key:    fieldtrack:location:{user_id}
Type:   HASH  {lat, lng, accuracy, speed, battery_level, is_mock_gps, recorded_at}
Write:  every accepted location ping (HSET + EXPIRE)
TTL:    30 minutes, refreshed on every write
```

**TTL: 2 hours** (revised from the original 30 min when the GPS phase
landed): stationary cadence is 12 min and low-battery cadence is 20 min, but
offline devices can buffer for long stretches — a 2h window keeps the last
known position visible on the dashboard through normal connectivity gaps.
Freshness (Active/Idle/stale) is derived from the `recorded_at` field inside
the hash, NOT from key existence; key expiry just garbage-collects truly
dead entries.

## 2. Attendance state machine

```
Key:    fieldtrack:attendance:state:{user_id}
Type:   HASH  {state: STARTED|ON_BREAK|RESUMED|ENDED, attendance_id, since}
Write:  on every attendance transition; deleted on END
TTL:    36 hours
```

**Why 36 h (not none):** the state is rebuilt from `attendance_sessions` on
cache miss, so the TTL is a self-cleaning safety net for employees who forget
to END — long enough to span any shift + overnight, short enough that stale
state never leaks into the next-next day. Validating transitions
(BREAK only after START, etc.) hits this key instead of querying Postgres on
every tap.

## 3. JWT blacklist (logout / revocation)

```
Key:    fieldtrack:blacklist:{jti}
Type:   STRING "1"
Write:  on logout (both access + refresh jti) and on forced revocation
TTL:    exact remaining lifetime of the token (computed from its exp claim)
```

**Why remaining-lifetime TTL:** after a token's natural expiry the signature
check rejects it anyway — keeping the blacklist entry longer is pure waste.
Worst case ~15 min for access tokens, 7 days for refresh tokens. At 100
employees this is trivially small.

## 4. Rate limiting

```
Key:    fieldtrack:ratelimit:{user_id}:{endpoint}
Type:   STRING counter (INCR)
Write:  INCR per request; EXPIRE 60s set when counter == 1
TTL:    60 seconds (fixed window)
```

**Why fixed window:** O(1) per request, 1 key per user-endpoint pair. The
worst-case 2× edge burst is harmless for this product; Nginx's per-IP 30 r/s
zone is the coarse backstop against unauthenticated abuse.

## 5. Sync dedup

```
Key:    fieldtrack:sync:processed:{hash}
Type:   STRING "1"   (hash = SHA-256 of "user_id:timestamp_iso" per location
        record; other entity types use their own hash inputs)
Write:  SET NX EX — atomic claim; existing key ⇒ duplicate ⇒ counted as
        `skipped` in the batch result (still ACKed to the device)
TTL:    6 hours (location records)
```

**Why 6 h:** a device that uploaded a batch and lost the ACK retries within
minutes, not days — the on-device queue drains continuously whenever there's
connectivity. 6 h covers any realistic retry storm at ~1/100th the key count
of a 48 h window. `SET NX` makes the dedup race-free across both uvicorn
workers.

## 6. Refresh-token session fingerprint

```
Key:    fieldtrack:refresh:{user_id}
Type:   STRING sha256(current refresh token)
Write:  on login and on every rotation (overwrite); deleted on logout,
        password reset, and reuse detection
TTL:    7 days (refresh token lifetime)
```

**Why a fingerprint, not the token:** Redis never holds a usable credential.
**Why one key per user (single session):** new login kicks the old device —
deliberate anti-buddy-punching property for an attendance product, and it
makes reuse detection trivial: a structurally valid refresh JWT whose hash
≠ stored value is a rotated-out token being replayed ⇒ revoke the session,
audit `REFRESH_REUSE_DETECTED`.

## 7. Password-reset OTP

```
Key:    fieldtrack:otp:{email}
Type:   HASH {hash: sha256(otp), attempts: int}
Write:  on /auth/forgot-password (overwrite); deleted on successful reset,
        attempt exhaustion, or TTL
TTL:    10 minutes
```

**Why sha256 not bcrypt:** 6-digit space is brute-forceable offline either
way; defense is the 5-attempt counter + 10 min TTL, not hash cost. Counter
lives in the same hash so it can't outlive the OTP.

## 8. Login rate limit (pre-auth, per IP)

```
Key:    fieldtrack:ratelimit:login:{ip}
Type:   STRING counter (INCR)
TTL:    15 minutes (fixed window)
Limit:  5 attempts; breach returns 429 + Retry-After
```

**Why per-IP:** login is unauthenticated — IP is the only identity we have.
Nginx sets X-Real-IP; the app trusts it because only Nginx can reach the app.

---

## Memory budget (worst case, 100 employees)

| Pattern | Keys | Est. size |
|---|---|---|
| location | 100 | ~30 KB |
| attendance state | 100 | ~15 KB |
| blacklist | ~200/day live | ~20 KB |
| ratelimit | ~100 × endpoints live | ~50 KB |
| sync dedup | ~5k over 48 h | ~500 KB |
| refresh allowlist | ~200 | ~20 KB |

**Total ≪ 1 MB.** The 200 MB cap is pure headroom; Redis will idle on this
workload at 100 employees — zero architecture change needed.
