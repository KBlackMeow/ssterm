import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/remote_cwd_parser.dart';

void main() {
  group('RemoteCwdParser.process', () {
    test('preserves UTF-8 at every possible chunk boundary', () {
      final bytes = utf8.encode('各体检机构体检项目详情');

      for (var split = 1; split < bytes.length; split++) {
        final parser = RemoteCwdParser();
        final first = parser.process(bytes.sublist(0, split));
        final second = parser.process(bytes.sublist(split));
        final cleaned = <int>[...first.cleaned, ...second.cleaned];

        expect(cleaned, bytes, reason: 'split at byte $split');
        expect(
          utf8.decode(cleaned),
          '各体检机构体检项目详情',
          reason: 'split at byte $split',
        );
        expect(first.cwd, isNull);
        expect(second.cwd, isNull);
      }
    });

    test('preserves UTF-8 when every byte arrives separately', () {
      final parser = RemoteCwdParser();
      final bytes = utf8.encode('各体检机构体检项目详情');
      final cleaned = <int>[];

      for (final byte in bytes) {
        cleaned.addAll(parser.process([byte]).cleaned);
      }

      expect(cleaned, bytes);
      expect(utf8.decode(cleaned), '各体检机构体检项目详情');
    });

    test('strips OSC 7 split across chunks without changing nearby UTF-8', () {
      final parser = RemoteCwdParser();
      final first = parser.process(utf8.encode('中\x1b]7;file://host/tmp/pro'));
      final second = parser.process(utf8.encode('ject%20one\x1b\\文'));

      expect(utf8.decode([...first.cleaned, ...second.cleaned]), '中文');
      expect(first.cwd, isNull);
      expect(second.cwd, '/tmp/project one');
    });

    test('preserves partial non-OSC escape sequences', () {
      final parser = RemoteCwdParser();
      final first = parser.process([0x1b]);
      final second = parser.process(utf8.encode('[31mred'));

      expect(first.cleaned, isEmpty);
      expect([...first.cleaned, ...second.cleaned], utf8.encode('\x1b[31mred'));
    });
  });

  group('RemoteCwdParser.process floods and terminators', () {
    test('passes large ordinary and ANSI output through untouched', () {
      final parser = RemoteCwdParser();
      final ordinary = List.filled(100000, '1234567890\n').join();
      final bytes = utf8.encode('$ordinary\x1b[31mred\x1b[0m');

      final parsed = parser.process(bytes);

      expect(parsed.cwd, isNull);
      expect(parsed.cleaned, bytes);
    });

    test('recognizes BEL termination and keeps the last cwd', () {
      final parser = RemoteCwdParser();
      final bytes = utf8.encode(
        '\x1b]7;file://host/first\x07text\x1b]7;file://host/second\x07',
      );

      final parsed = parser.process(bytes);

      expect(parsed.cwd, '/second');
      expect(utf8.decode(parsed.cleaned), 'text');
    });

    test('normalizes native OSC 7 values with the same safety checks', () {
      expect(
        RemoteCwdParser.pathFromFileUri('file://host/tmp/project%20one'),
        '/tmp/project one',
      );
      expect(
        RemoteCwdParser.pathFromFileUri('file://host/tmp/../secret'),
        isNull,
      );
    });
  });
}
