enum TerminalMouseButton {
  left(id: 0),

  middle(id: 1),

  right(id: 2),

  // andssh P1: xterm ctlseqs encodes wheel events as button codes
  // 64..67. Upstream's `64 + 4` conflates the raw button number with
  // the +64 wheel flag and emits 68/69, which tmux/less/vim ignore.
  wheelUp(id: 64, isWheel: true),

  wheelDown(id: 65, isWheel: true),

  wheelLeft(id: 66, isWheel: true),

  wheelRight(id: 67, isWheel: true),
  ;

  /// The id that is used to report a button press or release to the terminal.
  ///
  /// Mouse wheel up / down use button IDs 4 = 0100 (binary) and 5 = 0101 (binary).
  /// The bits three and four of the button are transposed by 64 and 128
  /// respectively, when reporting the id of the button and have have to be
  /// adjusted correspondingly.
  final int id;

  /// Whether this button is a mouse wheel button.
  final bool isWheel;

  const TerminalMouseButton({required this.id, this.isWheel = false});
}
