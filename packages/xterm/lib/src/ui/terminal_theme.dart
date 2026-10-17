import 'package:flutter/widgets.dart';

class TerminalTheme {
  const TerminalTheme({
    required this.cursor,
    required this.selection,
    required this.foreground,
    required this.background,
    required this.black,
    required this.white,
    required this.red,
    required this.green,
    required this.yellow,
    required this.blue,
    required this.magenta,
    required this.cyan,
    required this.brightBlack,
    required this.brightRed,
    required this.brightGreen,
    required this.brightYellow,
    required this.brightBlue,
    required this.brightMagenta,
    required this.brightCyan,
    required this.brightWhite,
    required this.searchHitBackground,
    required this.searchHitBackgroundCurrent,
    required this.searchHitForeground,
  });

  final Color cursor;
  final Color selection;

  final Color foreground;
  final Color background;

  final Color black;
  final Color red;
  final Color green;
  final Color yellow;
  final Color blue;
  final Color magenta;
  final Color cyan;
  final Color white;

  final Color brightBlack;
  final Color brightRed;
  final Color brightGreen;
  final Color brightYellow;
  final Color brightBlue;
  final Color brightMagenta;
  final Color brightCyan;
  final Color brightWhite;

  final Color searchHitBackground;
  final Color searchHitBackgroundCurrent;
  final Color searchHitForeground;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalTheme &&
          other.cursor == cursor &&
          other.selection == selection &&
          other.foreground == foreground &&
          other.background == background &&
          other.black == black &&
          other.white == white &&
          other.red == red &&
          other.green == green &&
          other.yellow == yellow &&
          other.blue == blue &&
          other.magenta == magenta &&
          other.cyan == cyan &&
          other.brightBlack == brightBlack &&
          other.brightRed == brightRed &&
          other.brightGreen == brightGreen &&
          other.brightYellow == brightYellow &&
          other.brightBlue == brightBlue &&
          other.brightMagenta == brightMagenta &&
          other.brightCyan == brightCyan &&
          other.brightWhite == brightWhite &&
          other.searchHitBackground == searchHitBackground &&
          other.searchHitBackgroundCurrent == searchHitBackgroundCurrent &&
          other.searchHitForeground == searchHitForeground;

  @override
  int get hashCode => Object.hashAll([
        cursor,
        selection,
        foreground,
        background,
        black,
        white,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        brightBlack,
        brightRed,
        brightGreen,
        brightYellow,
        brightBlue,
        brightMagenta,
        brightCyan,
        brightWhite,
        searchHitBackground,
        searchHitBackgroundCurrent,
        searchHitForeground,
      ]);
}
