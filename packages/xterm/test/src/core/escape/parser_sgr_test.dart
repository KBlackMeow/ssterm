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
  });
}
