import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_session_registry.dart';

void main() {
  group('AgentSessionRegistry', () {
    late Directory directory;
    late File indexFile;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('agent-registry-test-');
      indexFile = File('${directory.path}/index.json');
    });

    tearDown(() => directory.delete(recursive: true));

    test('creates distinct sessions and excludes leased sessions', () async {
      final registry = AgentSessionRegistry(indexFile: indexFile);
      final first = await registry.createAndAcquire();
      final second = await registry.createAndAcquire();

      expect(first.session.id, isNot(second.session.id));
      expect(await registry.listAvailable(), isEmpty);

      await first.release();

      expect(
        (await registry.listAvailable()).map((session) => session.id),
        contains(first.session.id),
      );
    });

    test('rejects an already leased session until it is released', () async {
      final registry = AgentSessionRegistry(indexFile: indexFile);
      final lease = await registry.createAndAcquire();

      await expectLater(
        registry.acquire(lease.session.id),
        throwsA(isA<AgentSessionUnavailableException>()),
      );

      await lease.release();
      final resumed = await registry.acquire(lease.session.id);
      expect(resumed.session.id, lease.session.id);
    });

    test('shares process-local leases across registry instances', () async {
      final first = AgentSessionRegistry(indexFile: indexFile);
      final lease = await first.createAndAcquire();

      final second = AgentSessionRegistry(indexFile: indexFile);
      await expectLater(
        second.acquire(lease.session.id),
        throwsA(isA<AgentSessionUnavailableException>()),
      );

      await lease.release();
      final resumed = await second.acquire(lease.session.id);

      expect(resumed.session.id, lease.session.id);
    });

    test('does not delete a leased session', () async {
      final registry = AgentSessionRegistry(indexFile: indexFile);
      final lease = await registry.createAndAcquire();

      await expectLater(
        registry.delete(lease.session.id),
        throwsA(isA<AgentSessionUnavailableException>()),
      );

      await lease.release();
      await registry.delete(lease.session.id);
      expect(await registry.listAvailable(), isEmpty);
    });
  });
}
