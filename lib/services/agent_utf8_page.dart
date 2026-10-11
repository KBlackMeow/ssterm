import 'dart:convert';

/// Decode a bounded byte page without splitting a UTF-8 character at its end.
class AgentUtf8Page {
  AgentUtf8Page._();

  static ({String text, int consumed}) decode(
    List<int> bytes, {
    required bool hasMore,
  }) {
    if (bytes.isEmpty) return (text: '', consumed: 0);
    if (hasMore) {
      for (
        var trailing = 0;
        trailing <= 3 && trailing < bytes.length;
        trailing++
      ) {
        final length = bytes.length - trailing;
        try {
          return (
            text: utf8.decode(bytes.sublist(0, length)),
            consumed: length,
          );
        } on FormatException {
          // The last character may continue on the next page.
        }
      }
    }
    // Malformed source bytes still advance the cursor instead of looping.
    return (
      text: utf8.decode(bytes, allowMalformed: true),
      consumed: bytes.length,
    );
  }
}
