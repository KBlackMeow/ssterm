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
  });
}
