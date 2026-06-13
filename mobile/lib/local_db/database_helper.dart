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
  static const _dbVersion = 1;

  Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    _db = await openDatabase(
      _dbName,
      version: _dbVersion,
      onCreate: _onCreate,
    );
    return _db!;
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
