import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../../../core/storage/token_storage.dart';
import '../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../../../local_db/database_helper.dart';
import '../../../services/sync/connectivity_service.dart';
import '../models/user.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(apiClientProvider),
    ref.watch(tokenStorageProvider),
    ref.watch(connectivityServiceProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

class AuthRepository {
  AuthRepository(this._api, this._tokens, this._connectivity, this._prefs);

  final SharedPreferences _prefs;

  final ApiClient _api;
  final TokenStorage _tokens;
  final ConnectivityService _connectivity;

  /// Last profile fetched successfully (login/me/update) — see
  /// TokenStorage.userJson for why this exists.
  User? get cachedUser {
    final json = _tokens.userJson;
    if (json == null) return null;
    try {
      return User.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheUser(User user) =>
      _tokens.saveUserJson(jsonEncode(user.toJson()));

  // Survives _tokens.clear() because it uses a different key prefix.
  static const _kLastUserId = 'session_last_user_id';

  Future<User> login(String email, String password) async {
    // Read before tokens are cleared — survives logout because it's stored
    // under a key that _tokens.clear() does not touch.
    final previousUserId = _prefs.getInt(_kLastUserId);
    final data = await _api.post('/auth/login', body: {
      'email': email.trim().toLowerCase(),
      'password': password,
      'client': 'mobile',
    });
    await _tokens.save(
      access: data['access_token'] as String,
      refresh: data['refresh_token'] as String,
    );
    final user = User.fromJson(data['user'] as Map<String, dynamic>);
    await _cacheUser(user);
    await _prefs.setInt(_kLastUserId, user.id);
    // Different employee on the same device: wipe the previous user's unsynced
    // queue so their pending visits/farmers don't sync under the new session.
    if (previousUserId != null && previousUserId != user.id) {
      await DatabaseHelper.instance.clearAllUserData();
    }
    return user;
  }

  Future<User> me() async {
    final data = await _api.get('/auth/me');
    final user = User.fromJson(data);
    await _cacheUser(user);
    return user;
  }

  Future<void> logout() async {
    try {
      await _api.post('/auth/logout');
    } catch (_) {
      // Offline logout still logs out locally; server token expires anyway.
    }
    // Only wipe the read cache (SharedPreferences cached_* keys). The SQLite
    // pending queue (unsynced visits, farmers, etc.) is intentionally kept so
    // the same employee logging back in doesn't lose unsynced work. If a
    // *different* employee logs in next, login() detects the user-id change
    // and wipes the queue at that point.
    await _clearCachedPrefs();
    await _tokens.clear();
  }

  Future<void> _clearCachedPrefs() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith('cached_')).toList();
    for (final k in keys) {
      await _prefs.remove(k);
    }
  }

  Future<void> forgotPassword(String email) async {
    await _api.post('/auth/forgot-password',
        body: {'email': email.trim().toLowerCase()});
  }

  bool get hasStoredSession => _tokens.hasSession;

  /// Offline: merges the edit into the cached profile immediately (so the
  /// UI reflects it right away) and queues it — only ever one pending edit
  /// at a time, since this endpoint takes the full profile rather than a
  /// partial patch, so a second offline edit before the first syncs simply
  /// overwrites it (same "latest wins" reasoning as pending_visits' upsert
  /// fields).
  Future<User> updateProfile({
    required String name,
    required String phone,
    required String village,
    required String district,
    required String state,
  }) async {
    final body = {
      'name': name.trim(),
      'phone': phone.trim().isNotEmpty ? phone.trim() : null,
      'village': village.trim().isNotEmpty ? village.trim() : null,
      'district': district.trim().isNotEmpty ? district.trim() : null,
      'state': state.trim().isNotEmpty ? state.trim() : null,
    };
    if (!_connectivity.current) {
      final current = cachedUser;
      if (current == null) {
        throw const UnknownApiException(
          'No cached profile to edit offline — connect once, then retry.',
          'NO_CACHED_PROFILE',
        );
      }
      final updated = User(
        id: current.id,
        name: body['name'] as String,
        email: current.email,
        role: current.role,
        phone: body['phone'],
        teamId: current.teamId,
        profilePhotoUrl: current.profilePhotoUrl,
        village: body['village'],
        district: body['district'],
        state: body['state'],
      );
      await _tokens.savePendingProfileUpdateJson(jsonEncode(body));
      await _cacheUser(updated);
      return updated;
    }
    final data = await _api.patch('/auth/me', body: body);
    final user = User.fromJson(data);
    await _cacheUser(user);
    return user;
  }

  Future<User> uploadProfilePhoto(String filePath) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath),
    });
    try {
      final res = await _api.dio.post('/auth/me/profile-photo', data: form);
      final user = User.fromJson(res.data as Map<String, dynamic>);
      await _cacheUser(user);
      return user;
    } on DioException catch (e) {
      throw ApiClient.mapError(e);
    }
  }
}
