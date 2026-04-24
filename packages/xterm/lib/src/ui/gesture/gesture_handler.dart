import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.onLongPressStart,
    this.onLongPressTap,
    this.suppressInternalSelectionGestures = false,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  /// andssh P8: called at the moment the long-press is recognised (before
  /// any selection is attempted). Use to freeze SSH data writes so that
  /// the terminal buffer is stable while xterm builds its CellAnchors —
  /// without this, tmux redraws can detach anchors before selectWord
  /// returns, silently breaking selection.
  final GestureLongPressStartCallback? onLongPressStart;

  /// andssh P3: called when a long-press completes without any drag
  /// movement — i.e. the user held a finger still, then released. Lets
  /// the caller show a Paste / context menu, while the same gesture's
  /// drag path still produces a word/character selection.
  final GestureLongPressStartCallback? onLongPressTap;

  /// andssh P6: when true, xterm's built-in long-press / drag / double-
  /// tap selection handlers do NOT call [renderTerminal.selectWord] /
  /// [selectCharacters]. Use when the terminal is wrapped in a Flutter
  /// `SelectionArea` so the framework's own gesture recognizers drive
  /// selection via `SelectionContainerDelegate.dispatchSelectionEvent`
  /// instead. Otherwise xterm's recognizers win the gesture arena and
  /// the framework never sees the events — which means no teardrop
  /// handles and no adaptive selection toolbar.
  final bool suppressInternalSelectionGestures;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  DragStartDetails? _lastDragStartDetails;

  LongPressStartDetails? _lastLongPressStartDetails;

  // andssh P3: track whether the current long-press saw any drag
  // movement, so we can tell a "bare long-press tap" (paste menu
  // trigger) from a selection extension.
  bool _longPressMoved = false;

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      child: widget.child,
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onSecondaryTapDown,
      onTertiaryTapUp: onSecondaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onLongPressUp: onLongPressUp,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDoubleTapDown: onDoubleTapDown,
      // andssh P6: when suppressed, skip registering the long-press
      // and pan recognizers entirely so they don't win the gesture
      // arena from a wrapping [SelectableRegion].
      suppressLongPressAndPan: widget.suppressInternalSelectionGestures,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // andssh P9: don't send mouse-down on tap-down. Sending it here means
    // tmux/mouse-aware apps receive a button-press every time the user's
    // finger touches the screen — including at the start of what will
    // become a long-press. They respond immediately (scrolling, entering
    // copy mode, repositioning the cursor) and the buffer changes out
    // from under us before selectWord can run. Instead, we defer the
    // button-down to tap-up, where we send a paired down+up sequence so
    // the app sees a complete click. Long-presses now send no mouse
    // events at all — exactly what we want.
    callback?.call(details);
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    if (_shouldSendTapEvent) {
      if (widget.terminalController.suppressNextTapMouseEvent) {
        // andssh P10: this tap's only job was to dismiss our frozen
        // selection overlay. Don't poke the remote with a click that
        // would put it in a stale state for the next gesture.
        widget.terminalController.suppressNextTapMouseEvent = false;
      } else {
        // andssh P9: paired down+up so the app sees a complete click
        // (since we skipped the down in _tapDown).
        renderTerminal.mouseEvent(
          button,
          TerminalMouseButtonState.down,
          details.localPosition,
        );
        renderTerminal.mouseEvent(
          button,
          TerminalMouseButtonState.up,
          details.localPosition,
        );
      }
    }
    // andssh P10: always call the tap-up callback regardless of whether
    // the mouse-event path ran. Upstream gated this on `!handled` so the
    // IME-request logic in _onSingleTapUp never ran when the remote was
    // in mouse-reporting mode — meaning once the user manually closed
    // the keyboard in tmux, tapping could never bring it back.
    if (callback != null || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.right);
  }

  void onDoubleTapDown(TapDownDetails details) {
    if (widget.suppressInternalSelectionGestures) return;
    renderTerminal.selectWord(details.localPosition);
  }

  // andssh P8: notify caller first so the SSH stream is frozen before
  // any selectWord is called — guarantees tmux cannot redraw and detach
  // CellAnchors between freeze and selection.
  // andssh P3 (revised): now that the buffer is frozen, immediately
  // select the word at the long-press position so the user sees instant
  // feedback without needing to drag. Drag still extends the selection.
  void onLongPressStart(LongPressStartDetails details) {
    widget.onLongPressStart?.call(details); // P8: freeze first
    _lastLongPressStartDetails = details;
    _longPressMoved = false;
    if (!widget.suppressInternalSelectionGestures) {
      renderTerminal.selectWord(details.localPosition);
    }
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    _longPressMoved = true;
    if (widget.suppressInternalSelectionGestures) return;
    renderTerminal.selectWord(
      _lastLongPressStartDetails!.localPosition,
      details.localPosition,
    );
  }

  void onLongPressUp() {
    final start = _lastLongPressStartDetails;
    if (start != null && !_longPressMoved) {
      widget.onLongPressTap?.call(start);
    }
  }

  void onDragStart(DragStartDetails details) {
    _lastDragStartDetails = details;
    if (widget.suppressInternalSelectionGestures) return;
    details.kind == PointerDeviceKind.mouse
        ? renderTerminal.selectCharacters(details.localPosition)
        : renderTerminal.selectWord(details.localPosition);
  }

  void onDragUpdate(DragUpdateDetails details) {
    if (widget.suppressInternalSelectionGestures) return;
    renderTerminal.selectCharacters(
      _lastDragStartDetails!.localPosition,
      details.localPosition,
    );
  }
}
