import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/color.dart';
import 'package:xterm/src/core/escape/handler.dart';
import 'package:xterm/src/core/escape/parser_sgr.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('parseSgrParams', () {
    late MockEscapeHandler h;
    setUp(() => h = MockEscapeHandler());

    test('empty params resets cursor style', () {
      parseSgrParams(h, const []);
      verify(h.resetCursorStyle()).called(1);
    });

    test('SGR 0 resets cursor style', () {
      parseSgrParams(h, const [0]);
      verify(h.resetCursorStyle()).called(1);
    });

    test('SGR 1 sets bold', () {
      parseSgrParams(h, const [1]);
      verify(h.setCursorBold()).called(1);
    });

    test('SGR 4 sets underline', () {
      parseSgrParams(h, const [4]);
      verify(h.setCursorUnderline()).called(1);
    });

    test('SGR 24 unsets underline', () {
      parseSgrParams(h, const [24]);
      verify(h.unsetCursorUnderline()).called(1);
    });

    test('SGR 31 sets foreground red (16-color)', () {
      parseSgrParams(h, const [31]);
      verify(h.setForegroundColor16(NamedColor.red)).called(1);
    });

    test('SGR 38;2;255;128;0 sets foreground RGB', () {
      parseSgrParams(h, const [38, 2, 255, 128, 0]);
      verify(h.setForegroundColorRgb(255, 128, 0)).called(1);
    });

    test('SGR 38;5;200 sets foreground 256-color', () {
      parseSgrParams(h, const [38, 5, 200]);
      verify(h.setForegroundColor256(200)).called(1);
    });

    test('SGR 48;2;10;20;30 sets background RGB', () {
      parseSgrParams(h, const [48, 2, 10, 20, 30]);
      verify(h.setBackgroundColorRgb(10, 20, 30)).called(1);
    });

    test('SGR 49 resets background', () {
      parseSgrParams(h, const [49]);
      verify(h.resetBackground()).called(1);
    });

    test('SGR 97 sets bright white foreground', () {
      parseSgrParams(h, const [97]);
      verify(h.setForegroundColor16(NamedColor.brightWhite)).called(1);
    });

    test('multiple SGR params in one sequence', () {
      parseSgrParams(h, const [1, 31, 4]);
      verify(h.setCursorBold()).called(1);
      verify(h.setForegroundColor16(NamedColor.red)).called(1);
      verify(h.setCursorUnderline()).called(1);
    });

    test('SGR 4:0 resets underline style', () {
      parseSgrParams(h, const [4], [const [0]]);
      verify(h.setCursorUnderlineStyle(0)).called(1);
      verifyNever(h.setCursorUnderline());
    });

    test('SGR 4:1 sets straight underline style', () {
      parseSgrParams(h, const [4], [const [1]]);
      verify(h.setCursorUnderlineStyle(1)).called(1);
    });

    test('SGR 4:3 sets wavy underline style', () {
      parseSgrParams(h, const [4], [const [3]]);
      verify(h.setCursorUnderlineStyle(3)).called(1);
    });

    test('SGR 4 without sub-param sets plain underline', () {
      parseSgrParams(h, const [4]);
      verify(h.setCursorUnderline()).called(1);
    });

    test('SGR 38:2:r:g:b sets foreground RGB (colon sub-params)', () {
      parseSgrParams(h, const [38], [const [2, 10, 20, 30]]);
      verify(h.setForegroundColorRgb(10, 20, 30)).called(1);
    });

    test('SGR 38:5:index sets foreground 256-color (colon sub-params)', () {
      parseSgrParams(h, const [38], [const [5, 200]]);
      verify(h.setForegroundColor256(200)).called(1);
    });

    test('SGR 48:2:r:g:b sets background RGB (colon sub-params)', () {
      parseSgrParams(h, const [48], [const [2, 1, 2, 3]]);
      verify(h.setBackgroundColorRgb(1, 2, 3)).called(1);
    });

    test('SGR 53 sets overline', () {
      parseSgrParams(h, const [53]);
      verify(h.setCursorOverline()).called(1);
    });

    test('SGR 55 unsets overline', () {
      parseSgrParams(h, const [55]);
      verify(h.unsetCursorOverline()).called(1);
    });

    test('SGR 58:2:r:g:b sets underline color RGB (colon sub-params)', () {
      parseSgrParams(h, const [58], [const [2, 100, 150, 200]]);
      verify(h.setUnderlineColorRgb(100, 150, 200)).called(1);
    });

    test('SGR 58:5:index sets underline color 256 (colon sub-params)', () {
      parseSgrParams(h, const [58], [const [5, 42]]);
      verify(h.setUnderlineColor256(42)).called(1);
    });

    test('SGR 58;2;r;g;b sets underline color RGB (semicolon)', () {
      parseSgrParams(h, const [58, 2, 10, 20, 30]);
      verify(h.setUnderlineColorRgb(10, 20, 30)).called(1);
    });

    test('SGR 59 resets underline color', () {
      parseSgrParams(h, const [59]);
      verify(h.resetUnderlineColor()).called(1);
    });

    test('SGR 94 sets bright blue foreground (not brightBlack bug)', () {
      parseSgrParams(h, const [94]);
      verify(h.setForegroundColor16(NamedColor.brightBlue)).called(1);
    });
  });
}
