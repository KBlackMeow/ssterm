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
