import 'package:test/test.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

void main() {
  group('UnicodeV11.wcwidth', () {
    test('treats East Asian Ambiguous symbols as wide when requested', () {
      for (final char in ['℃', '℉', '①', '─']) {
        expect(
          unicodeV11.wcwidth(char.runes.single, ambiguousAsWide: true),
          2,
          reason: char,
        );
      }
    });

    test('keeps East Asian Ambiguous symbols narrow when requested', () {
      for (final char in ['℃', '℉', '①', '─']) {
        expect(
          unicodeV11.wcwidth(char.runes.single, ambiguousAsWide: false),
          1,
          reason: char,
        );
      }
    });

    test('preserves non-ambiguous width classes', () {
      expect(unicodeV11.wcwidth('A'.runes.single), 1);
      expect(unicodeV11.wcwidth('中'.runes.single), 2);
      expect(unicodeV11.wcwidth(0x0301), 0); // combining acute accent
    });
  });
}
