import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Typed access to .env. Features never call dotenv directly — if a key is
/// missing we fail at startup with a clear message, not mid-request.
abstract final class Env {
  static String get apiBaseUrl => _require('API_BASE_URL');
  static String get termsUrl => _require('TERMS_URL');

  static String _require(String key) {
    final value = dotenv.maybeGet(key);
    if (value == null || value.isEmpty) {
      throw StateError('.env is missing required key: $key');
    }
    return value;
  }
}
