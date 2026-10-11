import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_output_store.dart';

void main() {
  group('AgentOutputStore', () {
    late Directory directory;
    late AgentOutputStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('agent-output-test-');
      store = AgentOutputStore(directory: directory, sessionId: 'test');
    });

    tearDown(() => directory.delete(recursive: true));

    test('stores a bounded artifact with a compact preview', () async {
      final reference = await store.save('alpha\n${'x' * 20000}');

      expect(reference.id, matches(RegExp(r'^out-[a-f0-9]+$')));
      expect(reference.storedBytes, lessThanOrEqualTo(store.maxArtifactBytes));
      expect(reference.preview, contains('alpha'));
      expect(reference.preview.length, lessThanOrEqualTo(2050));
    });

    test('reads only an opaque artifact id and bounded range', () async {
      final reference = await store.save('0123456789');

      expect(await store.read(reference.id, offset: 3, maxBytes: 4), '3456');
      final page = await store.readPage(reference.id, offset: 3, maxBytes: 4);
      expect(page.content, '3456');
      expect(page.nextOffset, 7);
      expect(page.hasMore, isTrue);
      await expectLater(
        store.read('../outside', offset: 0, maxBytes: 4),
        throwsArgumentError,
      );
    });

    test('keeps a UTF-8 character intact across output pages', () async {
      final reference = await store.save('AB中C');
      final first = await store.readPage(reference.id, offset: 0, maxBytes: 4);
      expect(first.content, isNot(contains('�')));
      expect(first.nextOffset, greaterThan(0));
      final rest = await store.readPage(
        reference.id,
        offset: first.nextOffset,
        maxBytes: 8,
      );
      expect('${first.content}${rest.content}', 'AB中C');
    });

    test('does not store half a UTF-8 character at the artifact cap', () async {
      final limited = AgentOutputStore(
        directory: directory,
        sessionId: 'unicode-cap',
        maxArtifactBytes: 4,
        maxSessionBytes: 8,
      );
      final reference = await limited.save('AB中C');
      final page = await limited.readPage(reference.id, offset: 0, maxBytes: 8);
      expect(page.content, 'AB');
      expect(reference.storedBytes, 2);
      expect(reference.truncated, isTrue);
    });

    test('enforces the per-session storage limit', () async {
      final limited = AgentOutputStore(
        directory: directory,
        sessionId: 'limit',
        maxArtifactBytes: 8,
        maxSessionBytes: 10,
      );
      await limited.save('12345678');

      await expectLater(limited.save('abcdefgh'), throwsA(isA<StateError>()));
    });

    test('uses owner-only permissions on POSIX artifact files', () async {
      if (Platform.isWindows) return;
      final reference = await store.save('private output');
      final stat = await File('${directory.path}/${reference.id}.bin').stat();

      expect(stat.mode & 0x1ff, 0x180); // 0600
    });

    test('clears only its opaque artifact files', () async {
      final reference = await store.save('temporary output');
      final unrelated = File('${directory.path}/keep.txt');
      await unrelated.writeAsString('keep');

      await store.clear();

      expect(
        await File('${directory.path}/${reference.id}.bin').exists(),
        isFalse,
      );
      expect(await unrelated.exists(), isTrue);
    });
  });
}
