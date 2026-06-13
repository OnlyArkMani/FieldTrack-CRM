/// Typed exceptions mapped from the backend's {detail, code} error contract.
/// UI catches [ApiException] and shows [message] — never a raw Dio error.
sealed class ApiException implements Exception {
  const ApiException(this.message, this.code);

  final String message;
  final String code;

  @override
  String toString() => '$code: $message';
}

class NoConnectionException extends ApiException {
  const NoConnectionException()
      : super('No internet connection. Changes will sync when back online.',
            'NO_CONNECTION');
}

class TimeoutException extends ApiException {
  const TimeoutException()
      : super('Server took too long to respond. Try again.', 'TIMEOUT');
}

/// 401s. [code] distinguishes INVALID_CREDENTIALS / TOKEN_EXPIRED /
/// TOKEN_REVOKED etc. — the refresh interceptor branches on it.
class UnauthorizedException extends ApiException {
  const UnauthorizedException(super.message, super.code);
}

class ForbiddenException extends ApiException {
  const ForbiddenException(String message) : super(message, 'FORBIDDEN');
}

class RateLimitedException extends ApiException {
  const RateLimitedException(String message, this.retryAfterSeconds)
      : super(message, 'RATE_LIMITED');

  final int? retryAfterSeconds;
}

class ValidationException extends ApiException {
  const ValidationException(String message)
      : super(message, 'VALIDATION_ERROR');
}

class ServerException extends ApiException {
  const ServerException(
      [String message = 'Something went wrong on the server.'])
      : super(message, 'INTERNAL_ERROR');
}

class UnknownApiException extends ApiException {
  const UnknownApiException(super.message, super.code);
}
