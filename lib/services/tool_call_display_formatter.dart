import 'dart:convert';

/// Produces a safe, bounded JSON representation for tool-call UI cards.
class ToolCallDisplayFormatter {
  ToolCallDisplayFormatter._();

  static const _maxValueLength = 2000;
  static final RegExp _sensitiveKey = RegExp(
    r'token|password|secret|api_key|authorization',
    caseSensitive: false,
  );

  static String formatArguments(Map<String, Object?> arguments) =>
      const JsonEncoder.withIndent('  ').convert(_sanitize(arguments));

  static Object? _sanitize(Object? value, {String? key}) {
    if (key != null && _sensitiveKey.hasMatch(key)) return '[redacted]';
    if (value is String) {
      if (value.length <= _maxValueLength) return value;
      return '${value.substring(0, _maxValueLength)}… [truncated]';
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _sanitize(
            entry.value,
            key: entry.key.toString(),
          ),
      };
    }
    if (value is Iterable) return [for (final item in value) _sanitize(item)];
    return value;
  }
}
