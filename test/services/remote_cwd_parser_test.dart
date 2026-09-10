import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/remote_cwd_parser.dart';

void main() {
  group('RemoteCwdParser.observe', () {
    test('ignores large ordinary and ANSI output', () {
      final parser = RemoteCwdParser();
      final ordinary = List.filled(100000, '1234567890\n').join();
      final bytes = utf8.encode('$ordinary\x1b[31mred\x1b[0m');

      expect(parser.observe(bytes), isNull);
    });

    test('recognizes OSC 7 split across chunks', () {
      final parser = RemoteCwdParser();

      expect(
        parser.observe(utf8.encode('prompt\x1b]7;file://host/tmp/pro')),
        isNull,
      );
      expect(
        parser.observe(utf8.encode('ject%20one\x1b\\rest')),
        '/tmp/project one',
      );
    });

    test('recognizes BEL termination and keeps the last cwd', () {
      final parser = RemoteCwdParser();
      final bytes = utf8.encode(
        '\x1b]7;file://host/first\x07text\x1b]7;file://host/second\x07',
      );

      expect(parser.observe(bytes), '/second');
    });
  });
}
