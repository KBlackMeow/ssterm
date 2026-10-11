import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_output_store.dart';
import 'package:ssterm/services/agent_read_tools.dart';
import 'package:ssterm/services/file_write_service.dart';

void main() {
  test(
    'read tools return bounded continuation data without UI state',
    () async {
      final root = await Directory.systemTemp.createTemp('ssterm-read-tools-');
      try {
        final path = '${root.path}/sample.txt';
        await File(path).writeAsString('alpha\nbeta\n');
        final store = AgentOutputStore(directory: root, sessionId: 'test');
        final reference = await store.save('0123456789');
        final tools = AgentReadTools(
          outputStore: store,
          fileSystem: const LocalFileSystemAdapter(),
        );
        final filePage = await tools.execute('read_file', {
          'path': path,
          'offset': 0,
          'max_bytes': 6,
        });
        expect(filePage.isError, isFalse);
        expect(filePage.content, contains('Continue with offset=6'));
        final outputPage = await tools.execute('read_output', {
          'id': reference.id,
          'offset': 3,
          'max_bytes': 4,
        });
        expect(outputPage.content, contains('3456'));
        expect(outputPage.content, contains('Continue with offset=7'));
        final search = await tools.execute('grep_file', {
          'path': path,
          'pattern': 'beta',
        });
        expect(search.content, contains('2: beta'));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('read tools turn invalid ranges into error results', () async {
    final root = await Directory.systemTemp.createTemp('ssterm-read-error-');
    try {
      final tools = AgentReadTools(
        outputStore: AgentOutputStore(directory: root, sessionId: 'test'),
      );
      final result = await tools.execute('read_output', {
        'id': '../outside',
        'offset': 0,
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('read_output failed'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('file pagination does not corrupt a split UTF-8 character', () async {
    final root = await Directory.systemTemp.createTemp('ssterm-utf8-page-');
    try {
      final path = '${root.path}/unicode.txt';
      await File(path).writeAsString('AB中C');
      final tools = AgentReadTools(
        outputStore: AgentOutputStore(directory: root, sessionId: 'test'),
        fileSystem: const LocalFileSystemAdapter(),
      );
      final first = await tools.execute('read_file', {
        'path': path,
        'offset': 0,
        'max_bytes': 4,
      });
      expect(first.content, contains('AB'));
      expect(first.content, contains('offset=2'));
      expect(first.content, isNot(contains('�')));
      final second = await tools.execute('read_file', {
        'path': path,
        'offset': 2,
        'max_bytes': 4,
      });
      expect(second.content, contains('中C'));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
