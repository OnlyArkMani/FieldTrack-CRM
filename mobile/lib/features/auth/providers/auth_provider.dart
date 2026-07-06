import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../../../core/widgets/app_messenger.dart';
import '../../attendance/data/attendance_repository.dart';
import '../../attendance/providers/attendance_provider.dart';
import '../data/auth_repository.dart';
import '../models/user.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.user,
    this.isLoading = false,
    this.error,
  });

  final AuthStatus status;
  final User? user;
  final bool isLoading;
  final String? error;

  AuthState copyWith({
    AuthStatus? status,
    User? user,
    bool? isLoading,
    String? error,
    bool clearError = false,
    bool clearUser = false,
  }) =>
      AuthState(
        status: status ?? this.status,
        user: clearUser ? null : (user ?? this.user),
        isLoading: isLoading ?? this.isLoading,
        error: clearError ? null : (error ?? this.error),
      );
}

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    // Session revoked by the network layer (refresh failed / second 401):
    // flip to unauthenticated — router redirects to /login automatically.
    ref.listen(sessionRevokedProvider, (prev, next) {
      if (prev != null && next != prev) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
    });

    Future.microtask(restoreSession);
    return const AuthState(status: AuthStatus.unknown);
  }

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  /// Called once at startup (splash). Stored refresh token => try /auth/me.
  Future<void> restoreSession() async {
    if (!_repo.hasStoredSession) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }
    try {
      final user = await _repo.me();
      state = AuthState(status: AuthStatus.authenticated, user: user);
    } on ApiException {
      // Interceptor already attempted refresh; if we land here, session dead.
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final user = await _repo.login(email, password);
      state = AuthState(status: AuthStatus.authenticated, user: user);
      // auto GPS clock-in on login.
      // Fires in the background so the user reaches the home screen
      // immediately. GPS denial, location unavailable, and 409 "already
      // started today" are all silently swallowed — login must never fail
      // because of an attendance side-effect.
      Future.microtask(_autoClockIn);
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  /// Acquires GPS and calls POST /attendance/start in the background.
  /// Uses [attendanceRepositoryProvider] directly to avoid a circular import
  /// with attendance_provider.dart (which already imports auth_provider).
  ///
  /// Best-effort: never blocks or fails login. But "best-effort" must not
  /// mean "silent" — if it doesn't land, the user needs to know so they can
  /// clock in manually from the Attendance tab instead of assuming they're
  /// checked in when they aren't.
  Future<void> _autoClockIn() async {
    try {
      // 1. Verify location services are on.
      if (!await Geolocator.isLocationServiceEnabled()) {
        showAppSnackBar(
            "Couldn't auto clock-in: location is off. Turn on GPS, then use "
            'Start on the Attendance tab.');
        return;
      }

      // 2. Check / request permission — never prompt aggressively here;
      //    the Attendance screen handles the full permission rationale.
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        showAppSnackBar(
            "Couldn't auto clock-in: location permission denied. Use Start "
            'on the Attendance tab.');
        return;
      }

      // 3. Get a high-accuracy fix (12-second timeout, same as AttendanceNotifier).
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );

      // 4. Clock in.
      await ref
          .read(attendanceRepositoryProvider)
          .start(pos.latitude, pos.longitude);

      // 5. Refresh the UI to reflect the auto check-in.
      ref.read(attendanceProvider.notifier).load(silent: true);
    } on ApiException catch (e) {
      // CONFLICT ("already started today") means the day is already clocked
      // in — that's a successful outcome, not a failure. Everything else
      // (network, server error) is a real failure worth surfacing.
      if (e.code != 'CONFLICT') {
        showAppSnackBar('Auto clock-in failed: ${e.message}');
      } else {
        ref.read(attendanceProvider.notifier).load(silent: true);
      }
    } catch (_) {
      // GPS timeout / position unavailable.
      showAppSnackBar(
          "Couldn't get your location — auto clock-in failed. Use Start on "
          'the Attendance tab.');
    }
  }

  Future<void> logout() async {
    // auto clock-out on logout (best-effort, awaited).
    // Must complete BEFORE _repo.logout() wipes the token, otherwise the
    // attendance API call would receive a 401.
    await _autoClockOut();
    await _repo.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Acquires GPS and calls POST /attendance/end (without work_summary) so
  /// the backend records "Auto clock-out on logout." Best-effort, but the
  /// user needs to know when it didn't land — their session stays open on
  /// the server until they clock out manually.
  Future<void> _autoClockOut() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        showAppSnackBar(
            "Couldn't auto clock-out: location is off. You're still clocked "
            'in — end your day from the Attendance tab next time you log in.');
        return;
      }
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        showAppSnackBar(
            "Couldn't auto clock-out: location permission denied. You're "
            "still clocked in — end your day from the Attendance tab next "
            'time you log in.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      await ref
          .read(attendanceRepositoryProvider)
          .endOnLogout(pos.latitude, pos.longitude);
    } on ApiException catch (e) {
      // CONFLICT ("already ended" / "never started") is a successful
      // outcome, not a failure. Everything else is worth surfacing.
      if (e.code != 'CONFLICT') {
        showAppSnackBar('Auto clock-out failed: ${e.message}');
      }
    } catch (_) {
      showAppSnackBar(
          "Couldn't get your location — auto clock-out failed. You're still "
          'clocked in — end your day from the Attendance tab next time you '
          'log in.');
    }
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
