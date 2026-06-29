import 'package:test/test.dart';
import 'package:xterm/src/core/mouse/reporter.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('MouseReporter', () {
    test('report() supports normal mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.normal,
      );

      // btn=chr(32+0)=' ', col=chr(32+1)='!', row=chr(32+1)='!'
      expect(output, equals('\x1B[M !!'));
    });

    test('report() supports utf mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.utf,
      );

      expect(output, equals('\x1B[M !!'));
    });

    test('report() supports sgr mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.sgr,
      );

      expect(output, equals('\x1B[<0;1;1M'));
    });

    test('report() supports urxvt mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.urxvt,
      );

      expect(output, equals('\x1B[32;1;1M'));
    });

    test('report() encodes modifier keys', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.sgr,
        shift: true,
        ctrl: true,
      );

      // shift=4, ctrl=16 → mods=20 → button=0+20=20
      expect(output, equals('\x1B[<20;1;1M'));
    });

    test('report() encodes wheel up in sgr mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.wheelUp,
        TerminalMouseButtonState.down,
        CellOffset(2, 3),
        MouseReportMode.sgr,
      );

      expect(output, equals('\x1B[<64;3;4M'));
    });

    test('report() encodes motion events in sgr mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.sgr,
        motion: true,
      );

      // motion bit = 32 → button=0+32=32
      expect(output, equals('\x1B[<32;1;1M'));
    });

    test('report() encodes hover (none button) in sgr mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.none,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.sgr,
        motion: true,
      );

      // none.id=3, motion=32 → 35
      expect(output, equals('\x1B[<35;1;1M'));
    });
  });
}
