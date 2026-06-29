enum TerminalMouseButton {
  left(id: 0),

  middle(id: 1),

  right(id: 2),

  // Used for ?1003h hover motion events (no button pressed).
  // Normal: chr(32 + 3 + 32) = 'C'  SGR: \e[<35;x;yM  (3 = release code, 32 = motion bit)
  none(id: 3),

  // xterm ctlseqs: wheel up/down/left/right are button codes 64/65/66/67.
  // SGR:    ESC [ < 64 ; col ; row M  (wheel up)
  // Normal: ESC [ M ` col row         (96 = 32+64)
  wheelUp(id: 64, isWheel: true),

  wheelDown(id: 65, isWheel: true),

  wheelLeft(id: 66, isWheel: true),

  wheelRight(id: 67, isWheel: true),
  ;

  /// The id that is used to report a button press or release to the terminal.
  ///
  /// Wheel buttons use xterm button codes 64–67 (not X11 button numbers 4–7).
  final int id;

  /// Whether this button is a mouse wheel button.
  final bool isWheel;

  const TerminalMouseButton({required this.id, this.isWheel = false});
}
