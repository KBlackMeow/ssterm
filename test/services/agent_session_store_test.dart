import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_session_store.dart';
import 'package:ssterm/services/agent_tool_contract.dart';

void main() {
  group('AgentSessionSnapshot', () {
    test('keeps only completed text transcript items', () {
      final snapshot = AgentSessionSnapshot.fromHistory(
        sessionId: 'local-default',
        history: [
          const AgentConversationItem.text(role: 'user', content: 'inspect'),
          AgentConversationItem.assistantToolCalls([
            AgentToolCall.fromRaw(
              id: 'call-secret',
              name: 'bash',
              arguments: {'command': r'echo $TOKEN'},
            )!,
          ]),
          const AgentConversationItem.text(role: 'assistant', content: 'Done'),
        ],
        savedAt: DateTime.utc(2026),
      );

      expect(snapshot.items, hasLength(2));
      expect(snapshot.items.map((item) => item.content), ['inspect', 'Done']);
    });

    test('rejects an unknown snapshot schema', () {
      expect(
        () => AgentSessionSnapshot.fromJson({
          'version': 99,
          'sessionId': 'local-default',
          'savedAt': '2026-01-01T00:00:00.000Z',
          'items': [],
        }),
        throwsFormatException,
      );
    });
  });

  group('AgentSessionStore', () {
    late Directory directory;
    late File file;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('agent-session-test-');
      file = File('${directory.path}/session.json');
    });

    tearDown(() => directory.delete(recursive: true));

    test('atomically saves and restores a snapshot', () async {
      final store = AgentSessionStore(file: file, sessionId: 'local-default');
      final snapshot = AgentSessionSnapshot.fromHistory(
        sessionId: 'local-default',
        history: [
          const AgentConversationItem.text(role: 'user', content: 'inspect'),
        ],
        savedAt: DateTime.utc(2026),
      );

      await store.save(snapshot);
      final result = await store.load();

      expect(result.state, AgentSessionLoadState.restored);
      expect(result.snapshot?.sessionId, 'local-default');
      expect(await file.exists(), isTrue);
      expect(
        (await directory
                .list()
                .where((entry) => entry.path.contains('.tmp-'))
                .toList())
            .isEmpty,
        isTrue,
      );
    });

    test(
      'quarantines corrupt snapshots instead of deserializing them',
      () async {
        await file.writeAsString('{not json');
        final store = AgentSessionStore(file: file);

        final result = await store.load();

        expect(result.state, AgentSessionLoadState.discarded);
        expect(await file.exists(), isFalse);
        expect(
          (await directory
                  .list()
                  .where((entry) => entry.path.contains('.corrupt-'))
                  .toList())
              .isNotEmpty,
          isTrue,
        );
      },
    );
  });
}
