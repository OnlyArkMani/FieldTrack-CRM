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

  String? get accessToken => _prefs.getString(_kAccess);
  String? get refreshToken => _prefs.getString(_kRefresh);
  bool get hasSession => refreshToken != null;

  Future<void> save({required String access, required String refresh}) async {
    await _prefs.setString(_kAccess, access);
    await _prefs.setString(_kRefresh, refresh);
  }

  Future<void> saveAccess(String access) => _prefs.setString(_kAccess, access);

  Future<void> clear() async {
    await _prefs.remove(_kAccess);
    await _prefs.remove(_kRefresh);
  }
}

final tokenStorageProvider = Provider<TokenStorage>(
  (ref) => TokenStorage(ref.watch(sharedPreferencesProvider)),
);
