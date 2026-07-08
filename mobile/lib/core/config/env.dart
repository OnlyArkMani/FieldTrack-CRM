import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Typed access to .env. Features never call dotenv directly — if a key is
/// missing we fail at startup with a clear message, not mid-request.
abstract final class Env {
  static String get apiBaseUrl => _require('API_BASE_URL');
  static String get termsUrl => _require('TERMS_URL');

  // Scheme + host (+ port) only, no path — for URLs the backend already
  // returns with a full path (e.g. photo download_url), since apiBaseUrl
  // itself includes the /api/v1 prefix and would otherwise double it up.
  static String get apiOrigin {
    final uri = Uri.parse(apiBaseUrl);
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null)
        .toString();
  }

  // Optional — only present in production builds (see mobile/.env.prod.example).
  // Falls back so existing dev .env files without these keys keep working.
  static String? get wsBaseUrl => dotenv.maybeGet('WS_BASE_URL');
  static String get environment => dotenv.maybeGet('ENVIRONMENT') ?? 'development';

  static String _require(String key) {
    final value = dotenv.maybeGet(key);
    if (value == null || value.isEmpty) {
      throw StateError('.env is missing required key: $key');
    }
    return value;
  }
}
