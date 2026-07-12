import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart' show sharedPreferencesProvider;

/// Access + refresh token persistence.
/// (shared_preferences per spec'd dependency list — see pubspec note.)
class TokenStorage {
  TokenStorage(this._prefs);
  final SharedPreferences _prefs;

  static const _kAccess = 'auth_access_token';
  static const _kRefresh = 'auth_refresh_token';
  static const _kUser = 'auth_cached_user';
  static const _kAttendanceToday = 'cached_attendance_today';
  static const _kAttendanceHistory = 'cached_attendance_history';
  static const _kPendingProfileUpdate = 'pending_profile_update';

  String? get accessToken => _prefs.getString(_kAccess);
  String? get refreshToken => _prefs.getString(_kRefresh);
  bool get hasSession => refreshToken != null;

  /// Last-known profile, serialized as raw JSON. Lets the app restore a
  /// session at startup while offline (no way to hit /auth/me to confirm
  /// the token) without forcing a login screen just because there's no
  /// signal yet — see AuthNotifier.restoreSession.
  String? get userJson => _prefs.getString(_kUser);
  Future<void> saveUserJson(String json) => _prefs.setString(_kUser, json);

  /// Last successful GET /attendance/today response — same idea as
  /// [userJson], for the same reason (see AttendanceRepository.today).
  String? get attendanceTodayJson => _prefs.getString(_kAttendanceToday);
  Future<void> saveAttendanceTodayJson(String json) =>
      _prefs.setString(_kAttendanceToday, json);

  /// Last successful GET /attendance/history first page (no cursor) — same
  /// idea, for "show the last fetched history" offline.
  String? get attendanceHistoryJson => _prefs.getString(_kAttendanceHistory);
  Future<void> saveAttendanceHistoryJson(String json) =>
      _prefs.setString(_kAttendanceHistory, json);

  /// A profile edit (name/phone/village/district/state) made offline,
  /// waiting to sync — see AuthRepository.updateProfile. Only ever one
  /// pending edit at a time; a later offline edit overwrites this outright
  /// (the update endpoint takes the full profile, not a partial patch).
  String? get pendingProfileUpdateJson =>
      _prefs.getString(_kPendingProfileUpdate);
  Future<void> savePendingProfileUpdateJson(String json) =>
      _prefs.setString(_kPendingProfileUpdate, json);
  Future<void> clearPendingProfileUpdate() =>
      _prefs.remove(_kPendingProfileUpdate);

  Future<void> save({required String access, required String refresh}) async {
    await _prefs.setString(_kAccess, access);
    await _prefs.setString(_kRefresh, refresh);
  }

  Future<void> saveAccess(String access) => _prefs.setString(_kAccess, access);

  Future<void> clear() async {
    await _prefs.remove(_kAccess);
    await _prefs.remove(_kRefresh);
    await _prefs.remove(_kUser);
    await _prefs.remove(_kAttendanceToday);
    await _prefs.remove(_kAttendanceHistory);
    await _prefs.remove(_kPendingProfileUpdate);
  }
}

final tokenStorageProvider = Provider<TokenStorage>(
  (ref) => TokenStorage(ref.watch(sharedPreferencesProvider)),
);
