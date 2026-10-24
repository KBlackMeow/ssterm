import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

Future<Uint8List> _raster(void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(160, 120);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final loader = FontLoader('JetBrainsMono');
    for (final face in ['Regular', 'Italic', 'BoldItalic']) {
      loader.addFont(
        Future.value(
          ByteData.sublistView(
            File('assets/fonts/JetBrainsMono-$face.ttf').readAsBytesSync(),
          ),
        ),
      );
    }
    await loader.load();
  });

  test('italic glyphs retain all ink at terminal cell boundaries', () async {
    for (final size in [14.0, 28.0, 40.0, 64.0]) {
      final style = TerminalStyle(fontFamily: 'JetBrainsMono', fontSize: size);
      final painter = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: style,
        textScaler: TextScaler.noScaling,
      );
      for (final char in List.generate(
        94,
        (i) => String.fromCharCode(33 + i),
      )) {
        final terminal = Terminal()..write('\x1b[3m$char');
        final cell = CellData.empty();
        terminal.buffer.lines[0].getCellData(0, cell);
        const offset = Offset(50, 20);
        final actual = await _raster((canvas) {
          painter.paintCellForeground(canvas, offset, cell);
        });
        final paragraph = ParagraphCache(1).performAndCacheLayout(
          char,
          style.toTextStyle(
            color: painter.resolveForegroundColor(0),
            italic: true,
          ),
          TextScaler.noScaling,
          char,
        );
        final expected = await _raster((canvas) {
          canvas.drawParagraph(paragraph, offset);
        });
        expect(
          actual,
          orderedEquals(expected),
          reason: '$char at $size px loses ink',
        );
      }
    }
  });
  test('neighboring backgrounds preserve italic overhang', () async {
    const style = TerminalStyle(fontFamily: 'JetBrainsMono', fontSize: 40);
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: style,
      textScaler: TextScaler.noScaling,
    );
    for (final char in List.generate(94, (i) => String.fromCharCode(33 + i))) {
      final terminal = Terminal()..resize(6, 1);
      terminal.write(' \x1b[40;3m$char$char \x1b[0m');
      final line = terminal.buffer.lines[0];
      const offset = Offset(10, 20);
      final actual = await _raster((canvas) {
        painter.paintLine(canvas, offset, line);
      });
      final expected = await _raster((canvas) {
        final cell = CellData.empty();
        for (var i = 0; i < line.length; i++) {
          line.getCellData(i, cell);
          painter.paintCellBackground(
            canvas,
            offset.translate(i * painter.cellSize.width, 0),
            cell,
          );
        }
        for (var i = 0; i < line.length; i++) {
          line.getCellData(i, cell);
          painter.paintCellForeground(
            canvas,
            offset.translate(i * painter.cellSize.width, 0),
            cell,
          );
        }
      });
      expect(
        actual,
        orderedEquals(expected),
        reason: 'background erases italic $char ink in adjacent cell',
      );
    }
  });
}
