import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the sync engine is doing right now, surfaced to the UI.
enum SyncPhase { idle, syncing, failed }

class SyncState {
  const SyncState({
    this.phase = SyncPhase.idle,
    this.pendingCount = 0,
    this.pendingLocationCount = 0,
    this.pendingSessionCount = 0,
    this.isOffline = false,
    this.lastSyncTime,
    this.lastSuccessfulSync,
    this.lastError,
    this.consecutiveFailures = 0,
  });

  final SyncPhase phase;
  final int pendingCount; // locations + sessions
  final int pendingLocationCount;
  final int pendingSessionCount;
  final bool isOffline; // from ConnectivityService
  final DateTime? lastSyncTime;
  final DateTime? lastSuccessfulSync;
  final String? lastError;
  final int consecutiveFailures;

  bool get isSyncing => phase == SyncPhase.syncing;
  bool get hasFailed => phase == SyncPhase.failed;
  bool get isCaughtUp => phase == SyncPhase.idle && pendingCount == 0;

  /// Offline but with buffered data waiting — the "saved locally" indicator.
  bool get isOfflineWithPending => isOffline && pendingCount > 0;

  SyncState copyWith({
    SyncPhase? phase,
    int? pendingCount,
    int? pendingLocationCount,
    int? pendingSessionCount,
    bool? isOffline,
    DateTime? lastSyncTime,
    DateTime? lastSuccessfulSync,
    String? lastError,
    bool clearError = false,
    int? consecutiveFailures,
  }) =>
      SyncState(
        phase: phase ?? this.phase,
        pendingCount: pendingCount ?? this.pendingCount,
        pendingLocationCount: pendingLocationCount ?? this.pendingLocationCount,
        pendingSessionCount: pendingSessionCount ?? this.pendingSessionCount,
        isOffline: isOffline ?? this.isOffline,
        lastSyncTime: lastSyncTime ?? this.lastSyncTime,
        lastSuccessfulSync: lastSuccessfulSync ?? this.lastSuccessfulSync,
        lastError: clearError ? null : (lastError ?? this.lastError),
        consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      );
}

/// Pure state holder. The SyncEngine pushes updates here; widgets read it.
/// Kept separate from the engine so the engine has no Riverpod build lifecycle
/// of its own and can run for the whole authenticated session.
class SyncNotifier extends Notifier<SyncState> {
  @override
  SyncState build() => const SyncState();

  void setSyncing() =>
      state = state.copyWith(phase: SyncPhase.syncing, clearError: true);

  /// Update the cached pending counts + connectivity (called between passes
  /// and whenever connectivity flips, so the offline indicator stays current
  /// even when no sync is running).
  void setPending({
    required int locations,
    required int sessions,
    bool? isOffline,
  }) =>
      state = state.copyWith(
        pendingCount: locations + sessions,
        pendingLocationCount: locations,
        pendingSessionCount: sessions,
        isOffline: isOffline,
      );

  void setOffline(bool offline) => state = state.copyWith(isOffline: offline);

  void setSuccess({required int locations, required int sessions}) =>
      state = state.copyWith(
        phase: SyncPhase.idle,
        pendingCount: locations + sessions,
        pendingLocationCount: locations,
        pendingSessionCount: sessions,
        lastSyncTime: DateTime.now(),
        lastSuccessfulSync: DateTime.now(),
        clearError: true,
        consecutiveFailures: 0,
      );

  void setFailure(
    String error, {
    required int locations,
    required int sessions,
  }) =>
      state = state.copyWith(
        phase: SyncPhase.failed,
        pendingCount: locations + sessions,
        pendingLocationCount: locations,
        pendingSessionCount: sessions,
        lastError: error,
        consecutiveFailures: state.consecutiveFailures + 1,
      );
}

final syncStatusProvider =
    NotifierProvider<SyncNotifier, SyncState>(SyncNotifier.new);
