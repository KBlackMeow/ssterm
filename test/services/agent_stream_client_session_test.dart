import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_stream_client_session.dart';

void main() {
  group('AgentStreamClientSession', () {
    late List<HttpClient> clients;
    late List<({HttpClient client, bool force})> closes;

    AgentStreamClientSession createSession() {
      return AgentStreamClientSession(
        clientFactory: () {
          final client = HttpClient();
          clients.add(client);
          return client;
        },
        clientCloser: (client, {required force}) {
          closes.add((client: client, force: force));
        },
      );
    }

    setUp(() {
      clients = [];
      closes = [];
    });

    tearDown(() {
      for (final client in clients) {
        client.close(force: true);
      }
    });

    test('reuses one client until reset', () {
      final session = createSession();

      expect(identical(session.client, session.client), isTrue);
      expect(clients, hasLength(1));
    });

    test('reset force-closes the current client and lazily replaces it', () {
      final session = createSession();
      final first = session.client;

      session.reset();

      expect(closes, [(client: first, force: true)]);
      final second = session.client;
      expect(identical(second, first), isFalse);
      expect(clients, hasLength(2));
    });

    test('close is terminal, forwards force, and is idempotent', () {
      final session = createSession();
      final client = session.client;

      session.close(force: true);
      session.close();

      expect(closes, [(client: client, force: true)]);
      expect(() => session.client, throwsStateError);
      expect(session.reset, returnsNormally);
      expect(closes, hasLength(1));
    });

    test('stale request lease cannot reset a replacement client', () {
      final session = createSession();
      final first = session.client;
      session.reset();
      final second = session.client;

      session.resetIfCurrent(first);

      expect(identical(session.client, second), isTrue);
      expect(closes, [(client: first, force: true)]);
    });
  });

  group('AgentStreamRetryPolicy', () {
    test('allows only two empty transient retries with exact delays', () {
      expect(
        AgentStreamRetryPolicy.delayAfterAttempt(1),
        const Duration(milliseconds: 500),
      );
      expect(
        AgentStreamRetryPolicy.delayAfterAttempt(2),
        const Duration(milliseconds: 1500),
      );
      expect(AgentStreamRetryPolicy.delayAfterAttempt(3), isNull);
      expect(
        AgentStreamRetryPolicy.canRetry(
          attempt: 1,
          hasText: false,
          hasReasoning: false,
          hasToolCalls: false,
          isActive: true,
          isTransient: true,
        ),
        isTrue,
      );
    });

    test('rejects retry after content, tool calls, or stale generation', () {
      bool retry({
        bool text = false,
        bool reasoning = false,
        bool tools = false,
        bool active = true,
      }) => AgentStreamRetryPolicy.canRetry(
        attempt: 1,
        hasText: text,
        hasReasoning: reasoning,
        hasToolCalls: tools,
        isActive: active,
        isTransient: true,
      );

      expect(retry(text: true), isFalse);
      expect(retry(reasoning: true), isFalse);
      expect(retry(tools: true), isFalse);
      expect(retry(active: false), isFalse);
    });
  });

  test('AgentStreamLogSanitizer redacts URI credentials and tokens', () {
    final sanitized = AgentStreamLogSanitizer.message(
      'HttpException: failed, uri=https://user:pass@example.com/v1?key=secret&token=also-secret',
    );

    expect(sanitized, isNot(contains('secret')));
    expect(sanitized, isNot(contains('user:pass')));
    expect(sanitized, contains('[REDACTED]'));
  });
}
