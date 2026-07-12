import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';

/// Offline-first SQLite store. CRITICAL PROPERTY: this is opened from BOTH
/// the main isolate and the background-locator isolate. sqflite serializes
/// access through the platform thread, so cross-isolate use is safe as long
/// as each isolate calls [DatabaseHelper.instance] (no cached cross-isolate
/// references) and we never hold long transactions.
///
/// sync_status convention (matches spec): 0=pending, 1=synced, 2=failed.
/// Synced rows are pruned after 24h — the server is the source of truth;
/// local storage is a buffer, not an archive (low-end devices, small disks).
class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  static const _dbName = 'fieldtrack.db';
  static const _dbVersion = 7;

  Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    _db = await openDatabase(
      _dbName,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  /// Test-only: closes the cached connection so the next [database] access
  /// reopens fresh (e.g. against a newly-deleted test database file). Never
  /// called from app code.
  @visibleForTesting
  Future<void> resetForTest() async {
    final existing = _db;
    if (existing != null && existing.isOpen) await existing.close();
    _db = null;
  }

  /// v1 -> v2: adds the offline farmer/visit queue (id_mappings,
  /// pending_farmers, cached_farmers). A device already on v1 has none of
  /// these tables yet, so they're created here rather than only in
  /// [_onCreate] (which only runs for a brand-new install).
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS id_mappings (
          local_id TEXT PRIMARY KEY,
          entity_type TEXT NOT NULL,
          server_id INTEGER,
          synced_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_farmers (
          local_id TEXT PRIMARY KEY,
          payload_json TEXT NOT NULL,
          batch_group_id TEXT,
          sync_status INTEGER NOT NULL DEFAULT 0,
          sync_error TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pending_farmers_status ON pending_farmers(sync_status)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pending_farmers_batch ON pending_farmers(batch_group_id)');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS cached_farmers (
          server_id INTEGER PRIMARY KEY,
          payload_json TEXT NOT NULL,
          cached_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_visits (
          local_id TEXT PRIMARY KEY,
          farmer_local_id TEXT,
          farmer_server_id INTEGER,
          check_in_payload_json TEXT NOT NULL,
          visit_server_id INTEGER,
          sync_status INTEGER NOT NULL DEFAULT 0,
          sync_error TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pending_visits_status ON pending_visits(sync_status)');
    }
    if (oldVersion < 4) {
      // Sub-actions for a visit whose check-in already happened (online or
      // previously synced offline) — see docs/OFFLINE_SYNC_PLAN.md. Each
      // holds the LATEST payload for that step (overwrite semantics, same
      // as the PATCH endpoints they mirror) and is cleared (set back to
      // NULL) once the sync engine successfully sends it. orders_json is
      // the one exception: a JSON array, since multiple orders can be
      // queued per visit.
      for (final col in [
        'location_remark_json',
        'notes_json',
        'livestock_json',
        'org_answers_json',
        'vet_json',
        'orders_json',
        'complete_json',
      ]) {
        await db.execute('ALTER TABLE pending_visits ADD COLUMN $col TEXT');
      }
    }
    if (oldVersion < 5) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_visit_plans (
          plan_date TEXT PRIMARY KEY,
          items_json TEXT NOT NULL,
          sync_status INTEGER NOT NULL DEFAULT 0,
          sync_error TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_leave_requests (
          leave_date TEXT PRIMARY KEY,
          sync_status INTEGER NOT NULL DEFAULT 0,
          sync_error TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_plan_item_actions (
          local_id TEXT PRIMARY KEY,
          item_id INTEGER NOT NULL,
          action TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          sync_status INTEGER NOT NULL DEFAULT 0,
          sync_error TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pending_plan_item_actions_status ON pending_plan_item_actions(sync_status)');
    }
    if (oldVersion < 7) {
      // Lets a queued cross-day move (`update_item` with a `plan_date`)
      // synthesize the item onto its *target* day before the move syncs —
      // previously the item just disappeared from the source day and
      // wasn't shown anywhere until sync completed. Holds the full
      // PlanItem.toJson() snapshot captured at the moment the move was
      // queued (see VisitPlanRepository.updateItem).
      await db.execute(
          'ALTER TABLE pending_plan_item_actions ADD COLUMN item_snapshot_json TEXT');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE pending_locations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        timestamp TEXT NOT NULL,          -- ISO8601 UTC, device capture time
        accuracy REAL,
        speed REAL,
        battery_level INTEGER,
        is_mock_gps INTEGER NOT NULL DEFAULT 0,
        sync_status INTEGER NOT NULL DEFAULT 0,  -- 0 pending, 1 synced, 2 failed
        sync_error TEXT,
        synced_at TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_pending_locations_status ON pending_locations(sync_status, id)');

    await db.execute('''
      CREATE TABLE pending_attendance_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        attendance_id INTEGER,
        type TEXT NOT NULL,               -- START/BREAK/RESUME/END
        timestamp TEXT NOT NULL,
        lat REAL,
        lng REAL,
        notes TEXT,
        sync_status INTEGER NOT NULL DEFAULT 0,
        sync_error TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE local_attendance_state (
        user_id INTEGER PRIMARY KEY,
        current_state TEXT NOT NULL,      -- STARTED/ON_BREAK/RESUMED/ENDED/NULL
        today_attendance_id INTEGER,
        last_updated TEXT NOT NULL
      )
    ''');
    // cached_map_tiles: owned entirely by flutter_map_tile_caching (its own
    // store) — deliberately NOT in this database.

    // ── Offline farmer/visit queue (see docs/OFFLINE_SYNC_PLAN.md) ────────
    await db.execute('''
      CREATE TABLE id_mappings (
        local_id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,        -- 'farmer' | 'visit'
        server_id INTEGER,
        synced_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_farmers (
        local_id TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,       -- same shape as FarmerRepository.create()'s body
        batch_group_id TEXT,              -- set for Farmer Meet attendees created together
        sync_status INTEGER NOT NULL DEFAULT 0,  -- 0 pending, 1 synced, 2 failed, 3 needs_attention
        sync_error TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_pending_farmers_status ON pending_farmers(sync_status)');
    await db.execute(
        'CREATE INDEX idx_pending_farmers_batch ON pending_farmers(batch_group_id)');

    // Read-through cache of GET /farmers responses — NOT a write queue.
    // Lets offline check-in target any farmer this phone has seen recently,
    // not just ones created this session.
    await db.execute('''
      CREATE TABLE cached_farmers (
        server_id INTEGER PRIMARY KEY,
        payload_json TEXT NOT NULL,
        cached_at TEXT NOT NULL
      )
    ''');

    // Check-in only for now — notes/livestock/orders/complete land in a
    // later migration once that slice is built (see OFFLINE_SYNC_PLAN.md).
    await db.execute('''
      CREATE TABLE pending_visits (
        local_id TEXT PRIMARY KEY,
        farmer_local_id TEXT,
        farmer_server_id INTEGER,
        check_in_payload_json TEXT NOT NULL,
        visit_server_id INTEGER,
        sync_status INTEGER NOT NULL DEFAULT 0,
        sync_error TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        location_remark_json TEXT,
        notes_json TEXT,
        livestock_json TEXT,
        org_answers_json TEXT,
        vet_json TEXT,
        orders_json TEXT,
        complete_json TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_pending_visits_status ON pending_visits(sync_status)');

    // One row per plan_date — a day's plan is a single upsert server-side,
    // so re-saving offline before the first save synced just overwrites
    // this same row rather than queuing a second one.
    await db.execute('''
      CREATE TABLE pending_visit_plans (
        plan_date TEXT PRIMARY KEY,
        items_json TEXT NOT NULL,
        sync_status INTEGER NOT NULL DEFAULT 0,
        sync_error TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_leave_requests (
        leave_date TEXT PRIMARY KEY,
        sync_status INTEGER NOT NULL DEFAULT 0,
        sync_error TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    // Single-item plan mutations (skip / carry-over / cross-day move /
    // status update) that are still online-only through their own PATCH/POST
    // endpoints — no whole-day upsert exists for them the way savePlan()
    // covers same-day field edits. Matched back to the item it targets by
    // `item_id` alone (no plan_date column needed): whichever day's
    // myPlan()/teamPlans() response happens to contain that item id gets
    // the pending effect merged in — see
    // VisitPlanRepository._applyPendingPlanItemActions.
    await db.execute('''
      CREATE TABLE pending_plan_item_actions (
        local_id TEXT PRIMARY KEY,
        item_id INTEGER NOT NULL,
        action TEXT NOT NULL,          -- 'skip' | 'carry_over' | 'update_status' | 'update_item'
        payload_json TEXT NOT NULL,    -- body sent to the server as-is once synced
        item_snapshot_json TEXT,       -- 'update_item' cross-day move only: PlanItem.toJson()
                                        -- snapshot, so the target day can show the item before sync
        sync_status INTEGER NOT NULL DEFAULT 0,
        sync_error TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_pending_plan_item_actions_status ON pending_plan_item_actions(sync_status)');
  }

  // ── pending_locations ──────────────────────────────────────────────────
  Future<int> insertLocationLog(PendingLocation log) async {
    final db = await database;
    return db.insert('pending_locations', log.toRow());
  }

  /// Oldest first so the server receives chronological batches.
  Future<List<PendingLocation>> getPendingLocations({int limit = 50}) async {
    final db = await database;
    final rows = await db.query(
      'pending_locations',
      where: 'sync_status = 0',
      orderBy: 'id ASC',
      limit: limit,
    );
    return rows.map(PendingLocation.fromRow).toList();
  }

  Future<int> pendingLocationCount() async {
    final db = await database;
    final n = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM pending_locations WHERE sync_status = 0'));
    return n ?? 0;
  }

  /// Spec-named alias used by SyncNotifier / the location callback.
  Future<int> getPendingLocationCount() => pendingLocationCount();

  Future<void> markSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE pending_locations SET sync_status = 1, synced_at = ? '
      'WHERE id IN ($placeholders)',
      [DateTime.now().toUtc().toIso8601String(), ...ids],
    );
  }

  Future<void> markFailed(int id, String error) async {
    final db = await database;
    await db.update(
      'pending_locations',
      // Failed rows stay retryable: status 2 is "failed last attempt", and
      // the sync engine re-picks them up after pending rows drain.
      {'sync_status': 2, 'sync_error': error},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Re-queue failed rows (called at the start of each sync pass — a row
  /// that failed on a flaky tower shouldn't be stranded forever).
  Future<void> requeueFailed() async {
    final db = await database;
    await db.update('pending_locations', {'sync_status': 0},
        where: 'sync_status = 2');
  }

  /// Keep the table small on low-end devices.
  Future<void> pruneSynced({Duration olderThan = const Duration(hours: 24)}) async {
    final db = await database;
    final cutoff =
        DateTime.now().toUtc().subtract(olderThan).toIso8601String();
    await db.delete('pending_locations',
        where: 'sync_status = 1 AND synced_at < ?', whereArgs: [cutoff]);
  }

  // ── local_attendance_state (read by the BACKGROUND ISOLATE) ───────────
  Future<LocalAttendanceState?> getLocalAttendanceState(int userId) async {
    final db = await database;
    final rows = await db.query('local_attendance_state',
        where: 'user_id = ?', whereArgs: [userId], limit: 1);
    if (rows.isEmpty) return null;
    return LocalAttendanceState.fromRow(rows.first);
  }

  Future<void> updateLocalAttendanceState(
    int userId, {
    required String currentState,
    int? todayAttendanceId,
  }) async {
    final db = await database;
    await db.insert(
      'local_attendance_state',
      {
        'user_id': userId,
        'current_state': currentState,
        'today_attendance_id': todayAttendanceId,
        'last_updated': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── pending_attendance_sessions (offline attendance, sync phase) ──────
  Future<int> insertPendingSession({
    int? attendanceId,
    required String type,
    required DateTime timestamp,
    double? lat,
    double? lng,
    String? notes,
  }) async {
    final db = await database;
    return db.insert('pending_attendance_sessions', {
      'attendance_id': attendanceId,
      'type': type,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'lat': lat,
      'lng': lng,
      'notes': notes,
      'sync_status': 0,
    });
  }

  /// Oldest first: attendance taps must replay in the order they happened so
  /// the server's state machine sees START before BREAK, etc.
  Future<List<PendingSession>> getPendingSessions({int limit = 200}) async {
    final db = await database;
    final rows = await db.query(
      'pending_attendance_sessions',
      where: 'sync_status = 0',
      orderBy: 'timestamp ASC, id ASC',
      limit: limit,
    );
    return rows.map(PendingSession.fromRow).toList();
  }

  Future<int> pendingSessionCount() async {
    final db = await database;
    final n = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM pending_attendance_sessions WHERE sync_status = 0'));
    return n ?? 0;
  }

  /// Spec-named alias used by SyncNotifier.
  Future<int> getPendingSessionCount() => pendingSessionCount();

  Future<void> markSessionsSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE pending_attendance_sessions SET sync_status = 1 '
      'WHERE id IN ($placeholders)',
      ids,
    );
  }

  Future<void> markSessionFailed(int id, String error) async {
    final db = await database;
    await db.update(
      'pending_attendance_sessions',
      {'sync_status': 2, 'sync_error': error},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Re-queue failed sessions at the start of each sync pass.
  Future<void> requeueFailedSessions() async {
    final db = await database;
    await db.update('pending_attendance_sessions', {'sync_status': 0},
        where: 'sync_status = 2');
  }

  /// Drop already-synced sessions (no synced_at column to age them; the server
  /// is the source of truth once they're marked synced).
  Future<void> deleteSyncedSessions() async {
    final db = await database;
    await db
        .delete('pending_attendance_sessions', where: 'sync_status = 1');
  }

  // ── id_mappings (client UUID -> real server ID) ───────────────────────
  Future<void> setIdMapping({
    required String localId,
    required String entityType,
    required int serverId,
  }) async {
    final db = await database;
    await db.insert(
      'id_mappings',
      {
        'local_id': localId,
        'entity_type': entityType,
        'server_id': serverId,
        'synced_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Null if [localId] hasn't synced yet.
  Future<int?> resolveServerId(String localId) async {
    final db = await database;
    final rows = await db.query('id_mappings',
        columns: ['server_id'], where: 'local_id = ?', whereArgs: [localId]);
    if (rows.isEmpty) return null;
    return rows.first['server_id'] as int?;
  }

  /// Records a farmer's local_id the moment it's created offline — *before*
  /// there's any server_id to go with it (server_id/synced_at start null,
  /// filled in later by setIdMapping once it syncs). Closes the Visit Plan
  /// farmer-race gap (see docs/OFFLINE_SYNC_PLAN.md): reverse-resolving a
  /// placeholder id back to its local_id used to require scanning
  /// pending_farmers, which stops containing the row the moment the farmer
  /// syncs — a farmer that syncs away in a brief connectivity blip between
  /// being created and a plan referencing it being saved became permanently
  /// unresolvable. id_mappings rows are never deleted, so scanning THIS
  /// table instead (see getFarmerIdMappingLocalIds) survives that race.
  /// `ConflictAlgorithm.ignore` so this can never clobber a real mapping
  /// that setIdMapping already wrote (shouldn't happen — creation always
  /// precedes sync — but cheap insurance).
  Future<void> insertIdMappingPlaceholder({
    required String localId,
    required String entityType,
  }) async {
    final db = await database;
    await db.insert(
      'id_mappings',
      {
        'local_id': localId,
        'entity_type': entityType,
        'server_id': null,
        'synced_at': null,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Every farmer local_id ever created on this phone, synced or not —
  /// the reverse-lookup fallback described on insertIdMappingPlaceholder.
  Future<List<String>> getFarmerIdMappingLocalIds() async {
    final db = await database;
    final rows = await db.query('id_mappings',
        columns: ['local_id'], where: 'entity_type = ?', whereArgs: ['farmer']);
    return rows.map((r) => r['local_id'] as String).toList();
  }

  // ── pending_farmers ────────────────────────────────────────────────────
  static const farmerStatusPending = 0;
  static const farmerStatusSynced = 1;
  static const farmerStatusFailed = 2; // transient — auto-retried
  static const farmerStatusNeedsAttention = 3; // permanent — user must act
  static const farmerMaxAutoRetries = 20;

  Future<void> insertPendingFarmer({
    required String localId,
    required String payloadJson,
    String? batchGroupId,
  }) async {
    final db = await database;
    await db.insert('pending_farmers', {
      'local_id': localId,
      'payload_json': payloadJson,
      'batch_group_id': batchGroupId,
      'sync_status': farmerStatusPending,
      'retry_count': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<PendingFarmer?> getPendingFarmer(String localId) async {
    final db = await database;
    final rows = await db
        .query('pending_farmers', where: 'local_id = ?', whereArgs: [localId]);
    if (rows.isEmpty) return null;
    return PendingFarmer.fromRow(rows.first);
  }

  /// Oldest first, so a Farmer Meet batch's attendees sync in the order
  /// they were created (matters for reconstructing `created[]` order).
  Future<List<PendingFarmer>> getPendingFarmers({
    int status = farmerStatusPending,
  }) async {
    final db = await database;
    final rows = await db.query(
      'pending_farmers',
      where: 'sync_status = ?',
      whereArgs: [status],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingFarmer.fromRow).toList();
  }

  Future<List<PendingFarmer>> getFarmersNeedingAttention() =>
      getPendingFarmers(status: farmerStatusNeedsAttention);

  /// All farmers still on this phone only (pending + transient-failed +
  /// needs_attention) — used to merge into the farmer list UI so a farmer
  /// created offline shows up immediately.
  Future<List<PendingFarmer>> getAllUnsyncedFarmers() async {
    final db = await database;
    final rows = await db.query(
      'pending_farmers',
      where: 'sync_status != ?',
      whereArgs: [farmerStatusSynced],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingFarmer.fromRow).toList();
  }

  /// Edit-before-sync: merge changes into the still-queued payload instead
  /// of hitting the API (there's no server id to PUT against yet). Also
  /// un-sticks a needs_attention row back to pending, since the edit may
  /// have fixed whatever the server rejected.
  Future<void> updatePendingFarmerPayload(
    String localId,
    String payloadJson,
  ) async {
    final db = await database;
    await db.update(
      'pending_farmers',
      {
        'payload_json': payloadJson,
        'sync_status': farmerStatusPending,
        'sync_error': null,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Synced rows are deleted outright — id_mappings keeps the local->server
  /// link permanently, and cached_farmers picks up the canonical copy on
  /// the next list/detail fetch. Nothing worth keeping around locally.
  Future<void> deletePendingFarmer(String localId) async {
    final db = await database;
    await db.delete('pending_farmers', where: 'local_id = ?', whereArgs: [localId]);
  }

  /// Transient failure (network/5xx): bump the retry counter and requeue,
  /// UNLESS it's exhausted its retries — then it needs a human, same as a
  /// validation rejection.
  Future<void> markFarmerTransientFailure(String localId, String error) async {
    final db = await database;
    final pending = await getPendingFarmer(localId);
    final nextRetryCount = (pending?.retryCount ?? 0) + 1;
    await db.update(
      'pending_farmers',
      {
        'sync_status': nextRetryCount >= farmerMaxAutoRetries
            ? farmerStatusNeedsAttention
            : farmerStatusFailed,
        'sync_error': error,
        'retry_count': nextRetryCount,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Permanent failure (422 validation): stop auto-retrying immediately,
  /// surface it, wait for the user to edit and resubmit.
  Future<void> markFarmerNeedsAttention(String localId, String error) async {
    final db = await database;
    await db.update(
      'pending_farmers',
      {'sync_status': farmerStatusNeedsAttention, 'sync_error': error},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Re-queue transient failures at the start of each sync pass. Rows in
  /// needs_attention are deliberately excluded — they only move again once
  /// the user edits them (see updatePendingFarmerPayload).
  Future<void> requeueFailedFarmers() async {
    final db = await database;
    await db.update('pending_farmers', {'sync_status': farmerStatusPending},
        where: 'sync_status = ?', whereArgs: [farmerStatusFailed]);
  }

  /// Manual "Retry" from the Needs Attention screen — the user didn't
  /// change anything, but wants the sync engine to try this one row again
  /// (e.g. a server-side fix landed, or they believe the rejection no
  /// longer applies).
  Future<void> requeueFarmer(String localId) async {
    final db = await database;
    await db.update(
      'pending_farmers',
      {'sync_status': farmerStatusPending, 'sync_error': null},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<int> pendingFarmerCount() async {
    final db = await database;
    final n = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM pending_farmers WHERE sync_status IN (?, ?)',
        [farmerStatusPending, farmerStatusFailed]));
    return n ?? 0;
  }

  // ── cached_farmers (read-through cache, NOT part of the sync queue) ───
  Future<void> upsertCachedFarmer(int serverId, String payloadJson) async {
    final db = await database;
    await db.insert(
      'cached_farmers',
      {
        'server_id': serverId,
        'payload_json': payloadJson,
        'cached_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertCachedFarmers(Map<int, String> byServerId) async {
    if (byServerId.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().toUtc().toIso8601String();
    for (final entry in byServerId.entries) {
      batch.insert(
        'cached_farmers',
        {'server_id': entry.key, 'payload_json': entry.value, 'cached_at': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<String?> getCachedFarmerJson(int serverId) async {
    final db = await database;
    final rows = await db.query('cached_farmers',
        columns: ['payload_json'], where: 'server_id = ?', whereArgs: [serverId]);
    if (rows.isEmpty) return null;
    return rows.first['payload_json'] as String;
  }

  Future<List<String>> getAllCachedFarmerJson() async {
    final db = await database;
    final rows = await db.query('cached_farmers', orderBy: 'cached_at DESC');
    return rows.map((r) => r['payload_json'] as String).toList();
  }

  // ── pending_visits (check-in only for now) ────────────────────────────
  static const visitStatusPending = 0;
  static const visitStatusSynced = 1;
  static const visitStatusFailed = 2; // transient — auto-retried
  static const visitStatusNeedsAttention = 3; // permanent — user must act
  static const visitMaxAutoRetries = 20;

  /// Exactly one of [farmerLocalId] / [farmerServerId] is set — the visit
  /// was checked in against either an offline-created farmer (resolved via
  /// id_mappings once that farmer syncs) or an already-synced one.
  Future<void> insertPendingVisit({
    required String localId,
    String? farmerLocalId,
    int? farmerServerId,
    required String checkInPayloadJson,
    int? visitServerId,
  }) async {
    final db = await database;
    await db.insert('pending_visits', {
      'local_id': localId,
      'farmer_local_id': farmerLocalId,
      'farmer_server_id': farmerServerId,
      'check_in_payload_json': checkInPayloadJson,
      'visit_server_id': visitServerId,
      'sync_status': visitStatusPending,
      'retry_count': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<PendingVisit?> getPendingVisit(String localId) async {
    final db = await database;
    final rows = await db
        .query('pending_visits', where: 'local_id = ?', whereArgs: [localId]);
    if (rows.isEmpty) return null;
    return PendingVisit.fromRow(rows.first);
  }

  Future<PendingVisit?> getPendingVisitByServerId(int serverId) async {
    final db = await database;
    final rows = await db.query('pending_visits',
        where: 'visit_server_id = ?', whereArgs: [serverId]);
    if (rows.isEmpty) return null;
    return PendingVisit.fromRow(rows.first);
  }

  /// A visit checked in ONLINE (real id from the start) that only goes
  /// offline partway through notes/livestock/orders/complete has no
  /// `pending_visits` row yet — check-in never queued one. This creates a
  /// row purely to hold those sub-actions, marked as already checked in
  /// (`visit_server_id` set at insert time, so the sync engine never
  /// re-posts check-in for it) — or reuses one from an earlier offline
  /// moment in the same visit. Returns the row's local_id, which every
  /// sub-action method then writes into.
  /// [checkInPayloadJson], when given, seeds a *newly created* row's
  /// check-in payload (moot for the sync engine — visitServerId being set
  /// already skips check-in sync — but read back by
  /// VisitPlanRepository._applyPendingVisitProgress to find plan_item_id).
  /// Ignored if a row already exists for this server id.
  Future<String> getOrCreatePendingVisitForServerId(
    int serverId, {
    String? checkInPayloadJson,
    int? farmerServerId,
  }) async {
    final existing = await getPendingVisitByServerId(serverId);
    if (existing != null) return existing.localId;
    final localId = 'srv-$serverId-${DateTime.now().microsecondsSinceEpoch}';
    await insertPendingVisit(
      localId: localId,
      checkInPayloadJson: checkInPayloadJson ?? '{}',
      visitServerId: serverId,
      farmerServerId: farmerServerId,
    );
    return localId;
  }

  /// Oldest first — visits should reach the server in the order they
  /// happened, same reasoning as pending_attendance_sessions.
  Future<List<PendingVisit>> getPendingVisits({
    int status = visitStatusPending,
  }) async {
    final db = await database;
    final rows = await db.query(
      'pending_visits',
      where: 'sync_status = ?',
      whereArgs: [status],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingVisit.fromRow).toList();
  }

  /// All not-yet-synced visits (any status except synced) — the "am I still
  /// waiting on this checked-in visit" set, e.g. for an "active visit"
  /// screen to fall back to while offline.
  Future<List<PendingVisit>> getAllUnsyncedVisits() async {
    final db = await database;
    final rows = await db.query(
      'pending_visits',
      where: 'sync_status != ?',
      whereArgs: [visitStatusSynced],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingVisit.fromRow).toList();
  }

  Future<void> deletePendingVisit(String localId) async {
    final db = await database;
    await db.delete('pending_visits', where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> markVisitTransientFailure(String localId, String error) async {
    final db = await database;
    final pending = await getPendingVisit(localId);
    final nextRetryCount = (pending?.retryCount ?? 0) + 1;
    await db.update(
      'pending_visits',
      {
        'sync_status': nextRetryCount >= visitMaxAutoRetries
            ? visitStatusNeedsAttention
            : visitStatusFailed,
        'sync_error': error,
        'retry_count': nextRetryCount,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> markVisitNeedsAttention(String localId, String error) async {
    final db = await database;
    await db.update(
      'pending_visits',
      {'sync_status': visitStatusNeedsAttention, 'sync_error': error},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> requeueFailedVisits() async {
    final db = await database;
    await db.update('pending_visits', {'sync_status': visitStatusPending},
        where: 'sync_status = ?', whereArgs: [visitStatusFailed]);
  }

  Future<List<PendingVisit>> getVisitsNeedingAttention() =>
      getPendingVisits(status: visitStatusNeedsAttention);

  /// Manual "Retry" from the Needs Attention screen — see requeueFarmer.
  Future<void> requeueVisit(String localId) async {
    final db = await database;
    await db.update(
      'pending_visits',
      {'sync_status': visitStatusPending, 'sync_error': null},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  // ── pending_visits sub-actions (notes/livestock/org-answers/vet/orders/
  // complete/location-remark) — each column holds the LATEST unsynced
  // payload for that step; a successful sync clears it back to NULL. Any
  // write also resets sync_status to pending, same reasoning as
  // updatePendingFarmerPayload: an edit may have fixed what got rejected.

  Future<void> _setVisitField(String localId, String column, String json) async {
    final db = await database;
    await db.update(
      'pending_visits',
      {column: json, 'sync_status': visitStatusPending, 'sync_error': null},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> setPendingVisitLocationRemark(String localId, String json) =>
      _setVisitField(localId, 'location_remark_json', json);
  Future<void> setPendingVisitNotes(String localId, String json) =>
      _setVisitField(localId, 'notes_json', json);
  Future<void> setPendingVisitLivestock(String localId, String json) =>
      _setVisitField(localId, 'livestock_json', json);
  Future<void> setPendingVisitOrgAnswers(String localId, String json) =>
      _setVisitField(localId, 'org_answers_json', json);
  Future<void> setPendingVisitVet(String localId, String json) =>
      _setVisitField(localId, 'vet_json', json);
  Future<void> setPendingVisitComplete(String localId, String json) =>
      _setVisitField(localId, 'complete_json', json);

  /// Clears a synced field. Used by the sync engine after each sub-action
  /// lands successfully — leaves the row's other pending fields untouched.
  Future<void> clearVisitField(String localId, String column) async {
    final db = await database;
    await db.update('pending_visits', {column: null},
        where: 'local_id = ?', whereArgs: [localId]);
  }

  /// Orders append (multiple can be queued per visit, unlike the other
  /// sub-actions which only ever keep the latest value).
  Future<void> appendPendingVisitOrder(String localId, String orderJson) async {
    final row = await getPendingVisit(localId);
    final existing = row?.ordersJson;
    final list = existing == null
        ? <dynamic>[]
        : (jsonDecode(existing) as List<dynamic>);
    list.add(jsonDecode(orderJson));
    await _setVisitField(localId, 'orders_json', jsonEncode(list));
  }

  /// Removes the first [count] orders from the queue (the ones the sync
  /// engine just confirmed) — oldest-first, matching the order they were
  /// added and therefore the order they're POSTed in.
  Future<void> removeSyncedVisitOrders(String localId, int count) async {
    final row = await getPendingVisit(localId);
    final existing = row?.ordersJson;
    if (existing == null) return;
    final list = jsonDecode(existing) as List<dynamic>;
    final remaining = list.skip(count).toList();
    final db = await database;
    await db.update(
      'pending_visits',
      {'orders_json': remaining.isEmpty ? null : jsonEncode(remaining)},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// True once check-in has a real server id and every sub-action field has
  /// synced (cleared) — nothing left in this row worth keeping.
  bool visitFullySynced(PendingVisit v) =>
      v.visitServerId != null &&
      v.locationRemarkJson == null &&
      v.notesJson == null &&
      v.livestockJson == null &&
      v.orgAnswersJson == null &&
      v.vetJson == null &&
      v.ordersJson == null &&
      v.completeJson == null;

  // ── pending_visit_plans ────────────────────────────────────────────────
  static const visitPlanStatusPending = 0;
  static const visitPlanStatusFailed = 2; // transient — auto-retried
  static const visitPlanStatusNeedsAttention = 3;
  static const visitPlanMaxAutoRetries = 20;

  /// One row per date — re-saving offline before the previous save synced
  /// just overwrites it (matches the server's own upsert-by-date behavior).
  Future<void> upsertPendingVisitPlan({
    required String planDate,
    required String itemsJson,
  }) async {
    final db = await database;
    await db.insert(
      'pending_visit_plans',
      {
        'plan_date': planDate,
        'items_json': itemsJson,
        'sync_status': visitPlanStatusPending,
        'sync_error': null,
        'retry_count': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<PendingVisitPlan?> getPendingVisitPlan(String planDate) async {
    final db = await database;
    final rows = await db.query('pending_visit_plans',
        where: 'plan_date = ?', whereArgs: [planDate]);
    if (rows.isEmpty) return null;
    return PendingVisitPlan.fromRow(rows.first);
  }

  Future<List<PendingVisitPlan>> getPendingVisitPlans({
    int status = visitPlanStatusPending,
  }) async {
    final db = await database;
    final rows = await db.query('pending_visit_plans',
        where: 'sync_status = ?', whereArgs: [status], orderBy: 'created_at ASC');
    return rows.map(PendingVisitPlan.fromRow).toList();
  }

  Future<void> deletePendingVisitPlan(String planDate) async {
    final db = await database;
    await db.delete('pending_visit_plans',
        where: 'plan_date = ?', whereArgs: [planDate]);
  }

  Future<void> markVisitPlanTransientFailure(String planDate, String error) async {
    final db = await database;
    final pending = await getPendingVisitPlan(planDate);
    final nextRetryCount = (pending?.retryCount ?? 0) + 1;
    await db.update(
      'pending_visit_plans',
      {
        'sync_status': nextRetryCount >= visitPlanMaxAutoRetries
            ? visitPlanStatusNeedsAttention
            : visitPlanStatusFailed,
        'sync_error': error,
        'retry_count': nextRetryCount,
      },
      where: 'plan_date = ?',
      whereArgs: [planDate],
    );
  }

  Future<void> markVisitPlanNeedsAttention(String planDate, String error) async {
    final db = await database;
    await db.update(
      'pending_visit_plans',
      {'sync_status': visitPlanStatusNeedsAttention, 'sync_error': error},
      where: 'plan_date = ?',
      whereArgs: [planDate],
    );
  }

  Future<void> requeueFailedVisitPlans() async {
    final db = await database;
    await db.update('pending_visit_plans', {'sync_status': visitPlanStatusPending},
        where: 'sync_status = ?', whereArgs: [visitPlanStatusFailed]);
  }

  Future<List<PendingVisitPlan>> getVisitPlansNeedingAttention() =>
      getPendingVisitPlans(status: visitPlanStatusNeedsAttention);

  /// Manual "Retry" from the Needs Attention screen — see requeueFarmer.
  Future<void> requeueVisitPlan(String planDate) async {
    final db = await database;
    await db.update(
      'pending_visit_plans',
      {'sync_status': visitPlanStatusPending, 'sync_error': null},
      where: 'plan_date = ?',
      whereArgs: [planDate],
    );
  }

  // ── pending_leave_requests ─────────────────────────────────────────────
  static const leaveStatusPending = 0;
  static const leaveStatusFailed = 2;
  static const leaveStatusNeedsAttention = 3;
  static const leaveMaxAutoRetries = 20;

  Future<void> upsertPendingLeaveRequest(String leaveDate) async {
    final db = await database;
    await db.insert(
      'pending_leave_requests',
      {
        'leave_date': leaveDate,
        'sync_status': leaveStatusPending,
        'sync_error': null,
        'retry_count': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<PendingLeaveRequest>> getPendingLeaveRequests({
    int status = leaveStatusPending,
  }) async {
    final db = await database;
    final rows = await db.query('pending_leave_requests',
        where: 'sync_status = ?', whereArgs: [status], orderBy: 'created_at ASC');
    return rows.map(PendingLeaveRequest.fromRow).toList();
  }

  Future<void> deletePendingLeaveRequest(String leaveDate) async {
    final db = await database;
    await db.delete('pending_leave_requests',
        where: 'leave_date = ?', whereArgs: [leaveDate]);
  }

  Future<void> markLeaveRequestTransientFailure(String leaveDate, String error) async {
    final db = await database;
    final rows = await db.query('pending_leave_requests',
        where: 'leave_date = ?', whereArgs: [leaveDate]);
    final current = rows.isEmpty ? 0 : rows.first['retry_count'] as int;
    final nextRetryCount = current + 1;
    await db.update(
      'pending_leave_requests',
      {
        'sync_status': nextRetryCount >= leaveMaxAutoRetries
            ? leaveStatusNeedsAttention
            : leaveStatusFailed,
        'sync_error': error,
        'retry_count': nextRetryCount,
      },
      where: 'leave_date = ?',
      whereArgs: [leaveDate],
    );
  }

  Future<void> markLeaveRequestNeedsAttention(String leaveDate, String error) async {
    final db = await database;
    await db.update(
      'pending_leave_requests',
      {'sync_status': leaveStatusNeedsAttention, 'sync_error': error},
      where: 'leave_date = ?',
      whereArgs: [leaveDate],
    );
  }

  Future<void> requeueFailedLeaveRequests() async {
    final db = await database;
    await db.update('pending_leave_requests', {'sync_status': leaveStatusPending},
        where: 'sync_status = ?', whereArgs: [leaveStatusFailed]);
  }

  Future<List<PendingLeaveRequest>> getLeaveRequestsNeedingAttention() =>
      getPendingLeaveRequests(status: leaveStatusNeedsAttention);

  /// Manual "Retry" from the Needs Attention screen — see requeueFarmer.
  Future<void> requeueLeaveRequest(String leaveDate) async {
    final db = await database;
    await db.update(
      'pending_leave_requests',
      {'sync_status': leaveStatusPending, 'sync_error': null},
      where: 'leave_date = ?',
      whereArgs: [leaveDate],
    );
  }

  // ── pending_plan_item_actions ────────────────────────────────────────
  static const planItemActionStatusPending = 0;
  static const planItemActionStatusFailed = 2;
  static const planItemActionStatusNeedsAttention = 3;
  static const planItemActionMaxAutoRetries = 20;

  Future<void> insertPendingPlanItemAction({
    required String localId,
    required int itemId,
    required String action,
    required String payloadJson,
    String? itemSnapshotJson,
  }) async {
    final db = await database;
    await db.insert('pending_plan_item_actions', {
      'local_id': localId,
      'item_id': itemId,
      'action': action,
      'payload_json': payloadJson,
      'item_snapshot_json': itemSnapshotJson,
      'sync_status': planItemActionStatusPending,
      'retry_count': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<PendingPlanItemAction>> getPendingPlanItemActions({
    int status = planItemActionStatusPending,
  }) async {
    final db = await database;
    final rows = await db.query('pending_plan_item_actions',
        where: 'sync_status = ?', whereArgs: [status], orderBy: 'created_at ASC');
    return rows.map(PendingPlanItemAction.fromRow).toList();
  }

  /// Any not-yet-synced action (pending + transient-failed + needs_attention)
  /// — used to merge pending effects into myPlan()/teamPlans(), same
  /// reasoning as getAllUnsyncedVisits/getAllUnsyncedFarmers.
  Future<List<PendingPlanItemAction>> getAllUnsyncedPlanItemActions() async {
    final db = await database;
    final rows = await db.query(
      'pending_plan_item_actions',
      where: 'sync_status IN (?, ?, ?)',
      whereArgs: [
        planItemActionStatusPending,
        planItemActionStatusFailed,
        planItemActionStatusNeedsAttention,
      ],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingPlanItemAction.fromRow).toList();
  }

  Future<void> deletePendingPlanItemAction(String localId) async {
    final db = await database;
    await db.delete('pending_plan_item_actions',
        where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> markPlanItemActionTransientFailure(String localId, String error) async {
    final db = await database;
    final rows = await db.query('pending_plan_item_actions',
        where: 'local_id = ?', whereArgs: [localId]);
    final current = rows.isEmpty ? 0 : rows.first['retry_count'] as int;
    final nextRetryCount = current + 1;
    await db.update(
      'pending_plan_item_actions',
      {
        'sync_status': nextRetryCount >= planItemActionMaxAutoRetries
            ? planItemActionStatusNeedsAttention
            : planItemActionStatusFailed,
        'sync_error': error,
        'retry_count': nextRetryCount,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> markPlanItemActionNeedsAttention(String localId, String error) async {
    final db = await database;
    await db.update(
      'pending_plan_item_actions',
      {'sync_status': planItemActionStatusNeedsAttention, 'sync_error': error},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> requeueFailedPlanItemActions() async {
    final db = await database;
    await db.update(
        'pending_plan_item_actions', {'sync_status': planItemActionStatusPending},
        where: 'sync_status = ?', whereArgs: [planItemActionStatusFailed]);
  }

  Future<List<PendingPlanItemAction>> getPlanItemActionsNeedingAttention() =>
      getPendingPlanItemActions(status: planItemActionStatusNeedsAttention);

  /// Manual "Retry" from the Needs Attention screen — see requeueFarmer.
  Future<void> requeuePlanItemAction(String localId) async {
    final db = await database;
    await db.update(
      'pending_plan_item_actions',
      {'sync_status': planItemActionStatusPending, 'sync_error': null},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Wipes every user-specific SQLite table. Called only when a *different*
  /// employee logs in — prevents the previous user's pending queue from
  /// syncing under the new session.
  Future<void> clearAllUserData() async {
    final db = await database;
    await db.transaction((txn) async {
      for (final table in [
        'cached_farmers',
        'pending_visits',
        'pending_farmers',
        'id_mappings',
        'pending_visit_plans',
        'pending_plan_item_actions',
        'pending_leave_requests',
        'pending_locations',
        'pending_attendance_sessions',
        'local_attendance_state',
      ]) {
        await txn.delete(table);
      }
    });
  }
}

// ── Row models ─────────────────────────────────────────────────────────────

class PendingLocation {
  const PendingLocation({
    this.id,
    required this.userId,
    required this.lat,
    required this.lng,
    required this.timestamp,
    this.accuracy,
    this.speed,
    this.batteryLevel,
    this.isMockGps = false,
  });

  final int? id;
  final int userId;
  final double lat;
  final double lng;
  final DateTime timestamp;
  final double? accuracy;
  final double? speed;
  final int? batteryLevel;
  final bool isMockGps;

  Map<String, Object?> toRow() => {
        'user_id': userId,
        'lat': lat,
        'lng': lng,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'accuracy': accuracy,
        'speed': speed,
        'battery_level': batteryLevel,
        'is_mock_gps': isMockGps ? 1 : 0,
        'sync_status': 0,
      };

  static PendingLocation fromRow(Map<String, Object?> row) => PendingLocation(
        id: row['id'] as int,
        userId: row['user_id'] as int,
        lat: row['lat'] as double,
        lng: row['lng'] as double,
        timestamp: DateTime.parse(row['timestamp'] as String),
        accuracy: row['accuracy'] as double?,
        speed: row['speed'] as double?,
        batteryLevel: row['battery_level'] as int?,
        isMockGps: (row['is_mock_gps'] as int? ?? 0) == 1,
      );

  /// Wire format for POST /location/batch.
  Map<String, Object?> toApiJson() => {
        'lat': lat,
        'lng': lng,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'accuracy': accuracy,
        'speed': speed,
        'battery_level': batteryLevel,
        'is_mock_gps': isMockGps,
      };
}

class PendingSession {
  const PendingSession({
    required this.id,
    this.attendanceId,
    required this.type,
    required this.timestamp,
    this.lat,
    this.lng,
    this.notes,
  });

  final int id;
  final int? attendanceId;
  final String type;
  final DateTime timestamp;
  final double? lat;
  final double? lng;
  final String? notes;

  static PendingSession fromRow(Map<String, Object?> row) => PendingSession(
        id: row['id'] as int,
        attendanceId: row['attendance_id'] as int?,
        type: row['type'] as String,
        timestamp: DateTime.parse(row['timestamp'] as String),
        lat: row['lat'] as double?,
        lng: row['lng'] as double?,
        notes: row['notes'] as String?,
      );

  /// Wire format for POST /sync/attendance-sessions.
  Map<String, Object?> toApiJson() => {
        'attendance_id': attendanceId,
        'type': type,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'lat': lat,
        'lng': lng,
        'notes': notes,
      };
}

class LocalAttendanceState {
  const LocalAttendanceState({
    required this.userId,
    required this.currentState,
    this.todayAttendanceId,
    required this.lastUpdated,
  });

  final int userId;
  final String currentState;
  final int? todayAttendanceId;
  final DateTime lastUpdated;

  /// The background isolate's gate: track ONLY in these states.
  bool get shouldTrack =>
      currentState == 'STARTED' || currentState == 'RESUMED';

  static LocalAttendanceState fromRow(Map<String, Object?> row) =>
      LocalAttendanceState(
        userId: row['user_id'] as int,
        currentState: row['current_state'] as String,
        todayAttendanceId: row['today_attendance_id'] as int?,
        lastUpdated: DateTime.parse(row['last_updated'] as String),
      );
}

/// A farmer created offline, not yet (or not successfully) synced.
/// [payloadJson] is the same body shape `FarmerRepository.create()` sends
/// online — sync just replays it as the create request.
class PendingFarmer {
  const PendingFarmer({
    required this.localId,
    required this.payloadJson,
    this.batchGroupId,
    required this.syncStatus,
    this.syncError,
    required this.retryCount,
    required this.createdAt,
  });

  final String localId;
  final String payloadJson;
  final String? batchGroupId;
  final int syncStatus;
  final String? syncError;
  final int retryCount;
  final DateTime createdAt;

  static PendingFarmer fromRow(Map<String, Object?> row) => PendingFarmer(
        localId: row['local_id'] as String,
        payloadJson: row['payload_json'] as String,
        batchGroupId: row['batch_group_id'] as String?,
        syncStatus: row['sync_status'] as int,
        syncError: row['sync_error'] as String?,
        retryCount: row['retry_count'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}

/// A visit checked in offline, not yet (or not successfully) synced.
/// [checkInPayloadJson] is the same body shape `VisitRepository.checkIn()`
/// sends online, with `farmer_id` filled in once it's resolvable (either
/// already known, or backfilled by the sync engine once the farmer syncs).
class PendingVisit {
  const PendingVisit({
    required this.localId,
    this.farmerLocalId,
    this.farmerServerId,
    required this.checkInPayloadJson,
    this.visitServerId,
    required this.syncStatus,
    this.syncError,
    required this.retryCount,
    required this.createdAt,
    this.locationRemarkJson,
    this.notesJson,
    this.livestockJson,
    this.orgAnswersJson,
    this.vetJson,
    this.ordersJson,
    this.completeJson,
  });

  final String localId;
  final String? farmerLocalId;
  final int? farmerServerId;
  final String checkInPayloadJson;
  final int? visitServerId;
  final int syncStatus;
  final String? syncError;
  final int retryCount;
  final DateTime createdAt;
  final String? locationRemarkJson;
  final String? notesJson;
  final String? livestockJson;
  final String? orgAnswersJson;
  final String? vetJson;
  final String? ordersJson; // JSON array
  final String? completeJson;

  static PendingVisit fromRow(Map<String, Object?> row) => PendingVisit(
        localId: row['local_id'] as String,
        farmerLocalId: row['farmer_local_id'] as String?,
        farmerServerId: row['farmer_server_id'] as int?,
        checkInPayloadJson: row['check_in_payload_json'] as String,
        visitServerId: row['visit_server_id'] as int?,
        syncStatus: row['sync_status'] as int,
        syncError: row['sync_error'] as String?,
        retryCount: row['retry_count'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
        locationRemarkJson: row['location_remark_json'] as String?,
        notesJson: row['notes_json'] as String?,
        livestockJson: row['livestock_json'] as String?,
        orgAnswersJson: row['org_answers_json'] as String?,
        vetJson: row['vet_json'] as String?,
        ordersJson: row['orders_json'] as String?,
        completeJson: row['complete_json'] as String?,
      );
}

class PendingVisitPlan {
  const PendingVisitPlan({
    required this.planDate,
    required this.itemsJson,
    required this.syncStatus,
    this.syncError,
    required this.retryCount,
    required this.createdAt,
  });

  final String planDate;
  final String itemsJson;
  final int syncStatus;
  final String? syncError;
  final int retryCount;
  final DateTime createdAt;

  static PendingVisitPlan fromRow(Map<String, Object?> row) => PendingVisitPlan(
        planDate: row['plan_date'] as String,
        itemsJson: row['items_json'] as String,
        syncStatus: row['sync_status'] as int,
        syncError: row['sync_error'] as String?,
        retryCount: row['retry_count'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}

class PendingLeaveRequest {
  const PendingLeaveRequest({
    required this.leaveDate,
    required this.syncStatus,
    this.syncError,
    required this.retryCount,
    required this.createdAt,
  });

  final String leaveDate;
  final int syncStatus;
  final String? syncError;
  final int retryCount;
  final DateTime createdAt;

  static PendingLeaveRequest fromRow(Map<String, Object?> row) => PendingLeaveRequest(
        leaveDate: row['leave_date'] as String,
        syncStatus: row['sync_status'] as int,
        syncError: row['sync_error'] as String?,
        retryCount: row['retry_count'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}

class PendingPlanItemAction {
  const PendingPlanItemAction({
    required this.localId,
    required this.itemId,
    required this.action,
    required this.payloadJson,
    this.itemSnapshotJson,
    required this.syncStatus,
    this.syncError,
    required this.retryCount,
    required this.createdAt,
  });

  final String localId;
  final int itemId;
  final String action; // 'skip' | 'carry_over' | 'update_status' | 'update_item'
  final String payloadJson;
  /// 'update_item' cross-day move only — PlanItem.toJson() at queue time.
  final String? itemSnapshotJson;
  final int syncStatus;
  final String? syncError;
  final int retryCount;
  final DateTime createdAt;

  static PendingPlanItemAction fromRow(Map<String, Object?> row) => PendingPlanItemAction(
        localId: row['local_id'] as String,
        itemId: row['item_id'] as int,
        action: row['action'] as String,
        payloadJson: row['payload_json'] as String,
        itemSnapshotJson: row['item_snapshot_json'] as String?,
        syncStatus: row['sync_status'] as int,
        syncError: row['sync_error'] as String?,
        retryCount: row['retry_count'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}
