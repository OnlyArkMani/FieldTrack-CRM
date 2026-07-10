import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
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
    } on NoConnectionException {
      _restoreFromCacheOrLogout();
    } on TimeoutException {
      _restoreFromCacheOrLogout();
    } on ApiException {
      // Interceptor already attempted refresh; if we land here, the token
      // itself was rejected (401/etc) — the session really is dead.
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  /// Offline (or the server's briefly unreachable) at startup — there's no
  /// way to ask /auth/me whether the token is still valid, but there's also
  /// no evidence it isn't. Trust the stored tokens and the last-known
  /// profile rather than forcing a login screen just because there's no
  /// signal yet; a real 401 surfaces later via the refresh interceptor
  /// (sessionRevokedProvider) and logs the user out then.
  void _restoreFromCacheOrLogout() {
    final cached = _repo.cachedUser;
    if (cached != null) {
      state = AuthState(status: AuthStatus.authenticated, user: cached);
    } else {
      // Only possible for a session that predates this cache (or an
      // install that's never completed a successful /auth/me) — nothing to
      // show, so this is the one offline case that still has to log out.
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final user = await _repo.login(email, password);
      state = AuthState(status: AuthStatus.authenticated, user: user);
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  Future<void> logout() async {
    await _repo.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  Future<bool> updateProfile({
    required String name,
    required String phone,
    required String village,
    required String district,
    required String stateVal,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final updatedUser = await _repo.updateProfile(
        name: name,
        phone: phone,
        village: village,
        district: district,
        state: stateVal,
      );
      state = AuthState(status: AuthStatus.authenticated, user: updatedUser);
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    }
  }

  Future<bool> uploadProfilePhoto(String filePath) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final updatedUser = await _repo.uploadProfilePhoto(filePath);
      state = AuthState(status: AuthStatus.authenticated, user: updatedUser);
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    }
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
