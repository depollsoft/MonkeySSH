enum TerminalMouseButton {
  left(id: 0),

  middle(id: 1),

  right(id: 2),

  wheelUp(id: 64 + 0, isWheel: true),

  wheelDown(id: 64 + 1, isWheel: true),

  wheelLeft(id: 64 + 2, isWheel: true),

  wheelRight(id: 64 + 3, isWheel: true),
  ;

  /// The id that is used to report a button press or release to the terminal.
  ///
  /// Buttons 4-7 are the wheel buttons. They are reported with bit 6 set (+64)
  /// and the button number transposed into the low two bits, giving 64 (up),
  /// 65 (down), 66 (left) and 67 (right). The button number must not simply be
  /// added on top of 64: 64 + 4 = 68 sets bit 2, which the encoding reads as a
  /// Shift modifier, so every wheel report carried a spurious Shift and strict
  /// applications rejected it as an invalid wheel event and did not scroll.
  final int id;

  /// Whether this button is a mouse wheel button.
  final bool isWheel;

  const TerminalMouseButton({required this.id, this.isWheel = false});
}
