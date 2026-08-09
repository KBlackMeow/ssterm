import 'dart:io';

typedef AgentHttpClientCloser =
    void Function(HttpClient client, {required bool force});

/// Owns the reusable HTTP connection pool for one agent-loop invocation.
class AgentStreamClientSession {
  AgentStreamClientSession({
    HttpClient Function()? clientFactory,
    AgentHttpClientCloser? clientCloser,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _clientCloser = clientCloser ?? _closeClient;

  final HttpClient Function() _clientFactory;
  final AgentHttpClientCloser _clientCloser;

  HttpClient? _client;
  bool _closed = false;

  HttpClient get client {
    if (_closed) {
      throw StateError('Agent stream client session is closed.');
    }
    return _client ??= _clientFactory();
  }

  /// Discards a potentially unhealthy pool while keeping this session usable.
  void reset() {
    if (_closed) return;
    final client = _client;
    _client = null;
    if (client != null) {
      _clientCloser(client, force: true);
    }
  }

  /// Resets only when [expected] still owns this session's active pool.
  void resetIfCurrent(HttpClient expected) {
    if (!identical(_client, expected)) return;
    reset();
  }

  /// Permanently closes this task-scoped session.
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    final client = _client;
    _client = null;
    if (client != null) {
      _clientCloser(client, force: force);
    }
  }

  static void _closeClient(HttpClient client, {required bool force}) {
    client.close(force: force);
  }
}

class AgentStreamRetryPolicy {
  static const _delays = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
  ];

  static Duration? delayAfterAttempt(int attempt) {
    final index = attempt - 1;
    return index >= 0 && index < _delays.length ? _delays[index] : null;
  }

  static bool canRetry({
    required int attempt,
    required bool hasText,
    required bool hasReasoning,
    required bool hasToolCalls,
    required bool isActive,
    required bool isTransient,
  }) {
    return delayAfterAttempt(attempt) != null &&
        !hasText &&
        !hasReasoning &&
        !hasToolCalls &&
        isActive &&
        isTransient;
  }
}

class AgentStreamLogSanitizer {
  static final _uriUserInfo = RegExp(r'(https?://)[^/@\s]+@');
  static final _sensitiveValue = RegExp(
    r'((?:[?&]|\b)(?:key|api[_-]?key|token|access[_-]?token|authorization)=)[^&\s,]+',
    caseSensitive: false,
  );

  static String message(Object error) {
    return '$error'
        .replaceAllMapped(
          _uriUserInfo,
          (match) => '${match.group(1)}[REDACTED]@',
        )
        .replaceAllMapped(
          _sensitiveValue,
          (match) => '${match.group(1)}[REDACTED]',
        );
  }
}
