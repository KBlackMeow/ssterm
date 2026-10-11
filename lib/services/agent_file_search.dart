import 'dart:convert';
import 'dart:math';

import 'file_write_service.dart';

/// Bounded literal search in one file on the active local or SSH adapter.
class AgentFileSearch {
  AgentFileSearch._();

  static Future<String> search({
    required FileSystemAdapter adapter,
    required String path,
    required String pattern,
    bool ignoreCase = false,
    int maxMatches = 50,
  }) async {
    if (pattern.isEmpty) throw ArgumentError('Search pattern is empty.');
    if (maxMatches < 1 || maxMatches > 100) {
      throw ArgumentError('maxMatches must be between 1 and 100.');
    }
    const maxScannedBytes = 1024 * 1024;
    const maxResultBytes = 8 * 1024;
    final needle = ignoreCase ? pattern.toLowerCase() : pattern;
    final matches = <String>[];
    final line = <int>[];
    var offset = 0;
    var lineNumber = 1;
    var resultBytes = 0;
    var totalBytes = 0;
    var hitLimit = false;
    var lineOverflow = false;
    var skippedLongLine = false;
    while (offset < maxScannedBytes) {
      final chunk = await adapter.readRange(
        path,
        offset: offset,
        maxBytes: 32768,
      );
      totalBytes = chunk.totalBytes;
      if (chunk.bytes.isEmpty) break;
      for (final byte in chunk.bytes) {
        if (byte == 10) {
          if (!lineOverflow) {
            final text = utf8.decode(line, allowMalformed: true);
            final haystack = ignoreCase ? text.toLowerCase() : text;
            final matchIndex = haystack.indexOf(needle);
            if (matchIndex >= 0) {
              final rendered = _renderMatch(
                lineNumber,
                text,
                matchIndex,
                needle.length,
              );
              final size = utf8.encode(rendered).length;
              if (matches.length >= maxMatches ||
                  resultBytes + size > maxResultBytes) {
                hitLimit = true;
                break;
              }
              matches.add(rendered);
              resultBytes += size;
            }
          }
          line.clear();
          lineOverflow = false;
          lineNumber++;
        } else if (!lineOverflow) {
          if (line.length < 8192) {
            line.add(byte);
          } else {
            lineOverflow = true;
            skippedLongLine = true;
            line.clear();
          }
        }
      }
      offset = chunk.nextOffset;
      if (hitLimit || !chunk.hasMore) break;
    }
    if (!hitLimit && offset >= totalBytes && line.isNotEmpty && !lineOverflow) {
      final text = utf8.decode(line, allowMalformed: true);
      final haystack = ignoreCase ? text.toLowerCase() : text;
      final matchIndex = haystack.indexOf(needle);
      if (matchIndex >= 0) {
        final rendered = _renderMatch(
          lineNumber,
          text,
          matchIndex,
          needle.length,
        );
        if (matches.length < maxMatches &&
            resultBytes + utf8.encode(rendered).length <= maxResultBytes) {
          matches.add(rendered);
        } else {
          hitLimit = true;
        }
      }
    }
    final status = hitLimit
        ? 'Match/output limit reached.'
        : offset < totalBytes
        ? 'Scanned first $offset of $totalBytes bytes; narrow the search or use bash for later ranges.'
        : 'Scanned $totalBytes bytes.';
    return '[Search $path: ${matches.length} match(es)]\n'
        '${matches.isEmpty ? '(none)' : matches.join('\n')}\n$status'
        '${skippedLongLine ? ' Lines longer than 8192 bytes were skipped.' : ''}';
  }

  static String _renderMatch(
    int lineNumber,
    String text,
    int matchIndex,
    int matchLength,
  ) {
    if (text.length <= 500) return '$lineNumber: $text';
    var start = max(0, matchIndex - 100);
    var end = min(text.length, start + 500);
    if (matchIndex + matchLength > end) {
      end = min(text.length, matchIndex + matchLength);
      start = max(0, end - 500);
    }
    if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start--;
    if (end < text.length && _isHighSurrogate(text.codeUnitAt(end - 1))) {
      end++;
    }
    return '$lineNumber: ${start > 0 ? '…' : ''}'
        '${text.substring(start, end)}${end < text.length ? '…' : ''}';
  }

  static bool _isLowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;
  static bool _isHighSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;
}
