import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/themes.dart';

void main() {
  test('ANSI bright white uses the theme bright-white color', () {
    final palette = PaletteBuilder(TerminalThemes.defaultTheme);

    expect(palette.paletteColor(15), TerminalThemes.defaultTheme.brightWhite);
  });
}
