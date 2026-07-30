import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/tool_call_display_formatter.dart';

void main() {
  test('redacts sensitive argument values recursively', () {
    final displayed = ToolCallDisplayFormatter.formatArguments({
      'path': '/tmp/book.pdf',
      'auth': {'api_key': 'very-secret'},
      'tokens': ['also-secret'],
    });

    expect(displayed, contains('/tmp/book.pdf'));
    expect(displayed, isNot(contains('very-secret')));
    expect(displayed, isNot(contains('also-secret')));
    expect(displayed, contains('[redacted]'));
  });

  test('truncates overlong displayed argument values', () {
    final displayed = ToolCallDisplayFormatter.formatArguments({
      'content': 'x' * 2001,
    });

    expect(displayed, contains('[truncated]'));
    expect(displayed.length, lessThan(2100));
  });
}
