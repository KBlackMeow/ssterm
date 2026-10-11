import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_file_search.dart';
import 'package:ssterm/services/file_write_service.dart';

void main() {
  test(
    'searches a file by literal text with line numbers and a match cap',
    () async {
      final root = await Directory.systemTemp.createTemp('ssterm-grep-test-');
      try {
        final path = '${root.path}/sample.txt';
        await File(path).writeAsString('Alpha\nbeta\nALPHA\n');
        final result = await AgentFileSearch.search(
          adapter: const LocalFileSystemAdapter(),
          path: path,
          pattern: 'alpha',
          ignoreCase: true,
        );
        expect(result, contains('1: Alpha'));
        expect(result, contains('3: ALPHA'));
        expect(result, isNot(contains('2: beta')));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('does not scan beyond one MiB', () async {
    final root = await Directory.systemTemp.createTemp('ssterm-grep-limit-');
    try {
      final path = '${root.path}/large.txt';
      await File(path).writeAsString('${'x' * (1024 * 1024)}\nneedle\n');
      final result = await AgentFileSearch.search(
        adapter: const LocalFileSystemAdapter(),
        path: path,
        pattern: 'needle',
      );
      expect(result, contains('0 match(es)'));
      expect(result, contains('Scanned first'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'reports skipped long lines instead of claiming a complete search',
    () async {
      final root = await Directory.systemTemp.createTemp('ssterm-grep-long-');
      try {
        final path = '${root.path}/long.txt';
        await File(path).writeAsString('${'x' * 8193}needle\nshort needle\n');
        final result = await AgentFileSearch.search(
          adapter: const LocalFileSystemAdapter(),
          path: path,
          pattern: 'needle',
        );
        expect(result, contains('2: short needle'));
        expect(result, contains('Lines longer than 8192 bytes were skipped.'));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('keeps a late match visible in a long line', () async {
    final root = await Directory.systemTemp.createTemp('ssterm-grep-snippet-');
    try {
      final path = '${root.path}/long.txt';
      await File(path).writeAsString('${'x' * 700}NEBULA-73${'y' * 200}\n');
      final result = await AgentFileSearch.search(
        adapter: const LocalFileSystemAdapter(),
        path: path,
        pattern: 'NEBULA-73',
      );
      expect(result, contains('NEBULA-73'));
      expect(result, contains('1: …'));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
