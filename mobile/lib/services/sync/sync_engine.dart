import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exceptions.dart';
import '../../local_db/database_helper.dart';
import '../location/location_service.dart';
import 'connectivity_service.dart';
import 'sync_notifications.dart';
import 'sync_status_provider.dart';

/// Moves the device's offline queue (SQLite) to the backend. Reliability is the
/// whole point, so the rules are explicit and defensive:
///
///  • MUTEX — only one sync runs at a time (`_running`). Triggers fire from
///    three places (connectivity-restored, 5-min heartbeat, backoff retry); the
///    lock makes overlap impossible.
///  • NEVER OFFLINE — every run re-verifies connectivity (radio + /health ping)
///    before touching the network.
///  • ORDER MATTERS — attendance sessions sync BEFORE locations.
///  • BATCHING — locations upload 50 at a time.
///  • PARTIAL FAILURE — a poison batch/row is marked failed and the queue moves
///    on; it isn't allowed to block everything behind it. A transport failure
///    (network/5xx/401) aborts the pass and arms exponential backoff.
///  • BACKOFF — 30s, 1m, 2m, 4m, 8m (capped). Resets on success.
///  • 3 STRIKES — after 3 consecutive failed passes, a persistent notification
///    tells the user their data is waiting.
///
/// FOREGROUND ENGINE: uses the Riverpod ApiClient (which refreshes tokens). The
/// background-locator isolate keeps its own token-free LocationSyncService; the
/// two never corrupt each other because the server dedupes and SQLite's
/// sync_status flags are idempotent.
class SyncEngine {
  SyncEngine(this._ref);
  final Ref _ref;

  static const _locationBatchSize = 50;
  static const _sessionBatchSize = 200;
  static const _periodicInterval = Duration(minutes: 5);
  static const _failureNotificationThreshold = 3;
  static const _backoffSchedule = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 4),
    Duration(minutes: 8),
  ];

  bool _running = false; // the mutex
  bool _started = false;
  int _failureStreak = 0;
  int _lastPending = 0; // for the "queue just cleared" haptic

  Timer? _periodic;
  Timer? _backoff;
  StreamSubscription<bool>? _connSub;

  ApiClient get _api => _ref.read(apiClientProvider);
  ConnectivityService get _connectivity =>
      _ref.read(connectivityServiceProvider);
  SyncNotifier get _status => _ref.read(syncStatusProvider.notifier);
  DatabaseHelper get _db => DatabaseHelper.instance;

  // ── Lifecycle ──────────────────────────────────────────────────────────
  void start() {
    if (_started) return;
    _started = true;
    // Trigger the moment we come back online; keep the offline flag current
    // either way so the "saved locally" indicator reacts immediately.
    _connSub = _connectivity.isOnline.listen((online) {
      _status.setOffline(!online);
      if (online) {
        unawaited(syncNow());
      } else {
        unawaited(_refreshPendingCount());
      }
    });
    // Heartbeat backstop while online.
    _periodic = Timer.periodic(_periodicInterval, (_) => unawaited(syncNow()));
    unawaited(_refreshPendingCount());
    unawaited(syncNow());
  }

  void stop() {
    _periodic?.cancel();
    _backoff?.cancel();
    _connSub?.cancel();
    _started = false;
  }

  // ── The pass ─────────────────────────────────────────────────────────
  Future<void> syncNow() async {
    if (_running) return; // mutex — never two at once
    if (!await _isOnline()) {
      await _refreshPendingCount();
      final (loc, ses) = await _counts();
      await _updateForegroundNotification(online: false, pending: loc + ses);
      return; // never sync offline
    }

    _running = true;
    _backoff?.cancel();
    _status.setSyncing();
    try {
      await _runSequence();
      _failureStreak = 0;
      await SyncNotifications.instance.dismiss();
      final (loc, ses) = await _counts();
      final pending = loc + ses;
      // A queue that just emptied (offline work successfully uploaded) gets a
      // light confirmation tap — but only the transition, not every empty pass.
      if (_lastPending > 0 && pending == 0) {
        unawaited(HapticFeedback.lightImpact());
      }
      _lastPending = pending;
      _status.setSuccess(locations: loc, sessions: ses);
      await _updateForegroundNotification(online: true, pending: pending);
    } catch (e) {
      _failureStreak++;
      final (loc, ses) = await _counts();
      final pending = loc + ses;
      _lastPending = pending;
      _status.setFailure(_message(e), locations: loc, sessions: ses);
      _armBackoff();
      if (_failureStreak >= _failureNotificationThreshold) {
        await SyncNotifications.instance.showSyncStuck(pendingCount: pending);
      }
      debugPrint('Sync pass failed (streak $_failureStreak): $e');
    } finally {
      _running = false;
    }
  }

  Future<bool> _isOnline() async {
    if (_connectivity.current) return true;
    return _connectivity.checkNow();
  }

  /// Ordered: sessions first (attendance must exist before its locations are
  /// meaningful), then locations in batches.
  Future<void> _runSequence() async {
    // Give previously-failed rows another chance each pass.
    await _db.requeueFailedSessions();
    await _db.requeueFailed();

    await _syncSessions();
    await _syncLocations();

    final (loc, ses) = await _counts();
    _status.setPending(
      locations: loc,
      sessions: ses,
      isOffline: !_connectivity.current,
    );
  }

  // ── Attendance sessions ──────────────────────────────────────────────
  Future<void> _syncSessions() async {
    final pending = await _db.getPendingSessions(limit: _sessionBatchSize);
    if (pending.isEmpty) return;

    // A transport error here throws → aborts the pass → backoff. A 2xx with a
    // per-record `errors` array is a PARTIAL success handled row-by-row.
    final resp = await _api.post(
      '/sync/attendance-sessions',
      body: {'sessions': pending.map((s) => s.toApiJson()).toList()},
    );

    final errorIndices = <int, String>{};
    for (final e in (resp['errors'] as List? ?? const [])) {
      if (e is Map && e['index'] is int) {
        errorIndices[e['index'] as int] = (e['reason'] as String?) ?? 'rejected';
      }
    }

    final syncedIds = <int>[];
    for (var i = 0; i < pending.length; i++) {
      final row = pending[i];
      if (errorIndices.containsKey(i)) {
        await _db.markSessionFailed(row.id, errorIndices[i]!);
      } else {
        // processed OR skipped(duplicate) — the server has it either way.
        syncedIds.add(row.id);
      }
    }
    await _db.markSessionsSynced(syncedIds);
    await _db.deleteSyncedSessions();
  }

  // ── Locations (batches of 50) ────────────────────────────────────────
  Future<void> _syncLocations() async {
    while (true) {
      final batch = await _db.getPendingLocations(limit: _locationBatchSize);
      if (batch.isEmpty) break;

      try {
        await _api.post(
          '/location/batch',
          body: {'records': batch.map((r) => r.toApiJson()).toList()},
        );
        // 2xx (processed or deduped-skipped) => the server has them all.
        await _db.markSynced([for (final r in batch) r.id!]);
      } on ValidationException {
        // 422: the whole batch is structurally poison. Isolate these rows so
        // the rest of the queue isn't stuck behind them, then keep draining.
        for (final r in batch) {
          await _db.markFailed(r.id!, 'validation rejected (422)');
        }
        continue;
      }
      // Other ApiExceptions (network / 5xx / 401) propagate → backoff.
    }
    await _db.pruneSynced();
  }

  // ── Backoff ──────────────────────────────────────────────────────────
  void _armBackoff() {
    final idx = (_failureStreak - 1).clamp(0, _backoffSchedule.length - 1);
    final delay = _backoffSchedule[idx];
    _backoff?.cancel();
    _backoff = Timer(delay, () => unawaited(syncNow()));
  }

  // ── Pending counts ───────────────────────────────────────────────────
  Future<(int, int)> _counts() async {
    final locations = await _db.getPendingLocationCount();
    final sessions = await _db.getPendingSessionCount();
    return (locations, sessions);
  }

  Future<void> _refreshPendingCount() async {
    final (loc, ses) = await _counts();
    _status.setPending(
      locations: loc,
      sessions: ses,
      isOffline: !_connectivity.current,
    );
  }

  /// Keep the persistent foreground-service notification text in sync with the
  /// online/offline state (what the employee sees in their notification shade).
  Future<void> _updateForegroundNotification({
    required bool online,
    required int pending,
  }) async {
    final text = online
        ? 'FieldTrack · Tracking active · Synced ${_minsAgo()} min ago'
        : 'FieldTrack · Tracking active · Saved locally ($pending points)';
    await LocationService.updateTrackingNotification(text);
  }

  int _minsAgo() {
    final last = _ref.read(syncStatusProvider).lastSuccessfulSync;
    if (last == null) return 0;
    return DateTime.now().difference(last).inMinutes;
  }

  String _message(Object e) {
    if (e is ApiException) return e.message;
    return 'Sync failed. Will retry automatically.';
  }
}

/// App-wide engine. Kept alive by the authenticated shell (see HomeShell), so
/// it runs only while logged in and stops on logout.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(ref);
  engine.start();
  ref.onDispose(engine.stop);
  return engine;
});
