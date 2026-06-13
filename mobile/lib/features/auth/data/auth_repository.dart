import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/token_storage.dart';
import '../models/user.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(apiClientProvider),
    ref.watch(tokenStorageProvider),
  );
});

class AuthRepository {
  AuthRepository(this._api, this._tokens);

  final ApiClient _api;
  final TokenStorage _tokens;

  static const _kUserCache = 'cached_user';

  Future<User> login(String email, String password) async {
    final data = await _api.post('/auth/login', body: {
      'email': email.trim().toLowerCase(),
      'password': password,
      'client': 'mobile',
    });
    await _tokens.save(
      access: data['access_token'] as String,
      refresh: data['refresh_token'] as String,
    );
    return User.fromJson(data['user'] as Map<String, dynamic>);
  }

  Future<User> me() async {
    final data = await _api.get('/auth/me');
    return User.fromJson(data);
  }

  Future<void> logout() async {
    try {
      await _api.post('/auth/logout');
    } catch (_) {
      // Offline logout still logs out locally; server token expires anyway.
    }
    await _tokens.clear();
  }

  Future<void> forgotPassword(String email) async {
    await _api.post('/auth/forgot-password',
        body: {'email': email.trim().toLowerCase()});
  }

  bool get hasStoredSession => _tokens.hasSession;
}
