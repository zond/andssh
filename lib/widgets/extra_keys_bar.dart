import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// A virtual-keyboard strip (two rows) for keys that Android's soft keyboard
/// doesn't expose (arrows, Home/End, PgUp/PgDn, F-keys, Tab, Esc) plus sticky
/// modifier toggles for Ctrl/Alt/Shift so combos like Ctrl+A (the default
/// tmux prefix) work with single-character keys from the soft keyboard.
///
/// Non-modifier keys auto-repeat when held, matching a hardware keyboard:
/// the action fires once immediately, then again after a 400 ms delay, then
/// every 50 ms while the finger is held down.
class ExtraKeysBar extends StatelessWidget {
  const ExtraKeysBar({
    super.key,
    required this.controller,
  });

  final ExtraKeysController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Material(
          color: theme.colorScheme.surfaceContainerHighest,
          elevation: 2,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildRow(_row1Children()),
                _buildRow(_row2Children()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(List<Widget> children) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        children: children,
      ),
    );
  }

  List<Widget> _row1Children() {
    return [
      _arrow('↑', () => controller.sendKey(TerminalKey.arrowUp)),
      _arrow('↓', () => controller.sendKey(TerminalKey.arrowDown)),
      _arrow('←', () => controller.sendKey(TerminalKey.arrowLeft)),
      _arrow('→', () => controller.sendKey(TerminalKey.arrowRight)),
      const SizedBox(width: 4),
      _toggle('Ctrl', controller.ctrl, controller.toggleCtrl),
      _toggle('Alt', controller.alt, controller.toggleAlt),
      _toggle('Shift', controller.shift, controller.toggleShift),
      const SizedBox(width: 4),
      _key('Esc', () => controller.sendKey(TerminalKey.escape)),
      _key('Tab', () => controller.sendKey(TerminalKey.tab)),
      _key('|', () => controller.sendText('|')),
      _key('/', () => controller.sendText('/')),
      _key('\\', () => controller.sendText('\\')),
      _key('~', () => controller.sendText('~')),
      _key('-', () => controller.sendText('-')),
      _key('_', () => controller.sendText('_')),
    ];
  }

  List<Widget> _row2Children() {
    return [
      _key('Home', () => controller.sendKey(TerminalKey.home)),
      _key('End', () => controller.sendKey(TerminalKey.end)),
      _key('PgUp', () => controller.sendKey(TerminalKey.pageUp)),
      _key('PgDn', () => controller.sendKey(TerminalKey.pageDown)),
      const SizedBox(width: 4),
      _key('Ins', () => controller.sendKey(TerminalKey.insert)),
      _key('Del', () => controller.sendKey(TerminalKey.delete)),
      const SizedBox(width: 4),
      for (int i = 1; i <= 12; i++)
        _key('F$i', () => controller.sendFKey(i)),
    ];
  }

  Widget _toggle(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 4),
      child: FilterChip(
        label: Text(label),
        selected: active,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _key(String label, VoidCallback onTap) {
    return _RepeatKey(label: label, onPress: onTap, controller: controller);
  }

  Widget _arrow(String label, VoidCallback onTap) {
    return _RepeatKey(
      label: label,
      onPress: onTap,
      controller: controller,
      circle: true,
    );
  }
}

/// Button that fires [onPress] once on touch-down and then again on a timer
/// while the pointer stays down — like a hardware key's auto-repeat. Cancels
/// the timer on pointer-up or pointer-cancel.
class _RepeatKey extends StatefulWidget {
  const _RepeatKey({
    required this.label,
    required this.onPress,
    required this.controller,
    this.circle = false,
  });

  final String label;
  final VoidCallback onPress;
  final ExtraKeysController controller;
  final bool circle;

  @override
  State<_RepeatKey> createState() => _RepeatKeyState();
}

class _RepeatKeyState extends State<_RepeatKey> {
  // Android's default key-repeat timings: ~400 ms until the first repeat,
  // ~50 ms between subsequent repeats.
  static const _initialDelay = Duration(milliseconds: 400);
  static const _repeatInterval = Duration(milliseconds: 50);
  // Safety net: if a gesture-arena steal (or missed pointer-up) ever
  // leaks past onPointerUp / onPointerCancel, time out the repeat
  // after a minute rather than spin forever until dispose. A 60 s hold
  // is far past any legitimate auto-repeat session.
  static const _maxHoldDuration = Duration(seconds: 60);

  Timer? _delayTimer;
  Timer? _repeatTimer;
  Timer? _holdTimeout;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    // Tell the controller to snapshot modifiers and pause per-key
    // auto-clear; every repeat during the hold reuses those modifiers
    // and the whole hold counts as a single consume on release.
    widget.controller.beginHold();
    widget.onPress();
    _delayTimer = Timer(_initialDelay, () {
      _repeatTimer =
          Timer.periodic(_repeatInterval, (_) => widget.onPress());
    });
    _holdTimeout = Timer(_maxHoldDuration, _stop);
  }

  void _stop() {
    _delayTimer?.cancel();
    _delayTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _holdTimeout?.cancel();
    _holdTimeout = null;
    widget.controller.endHold();
  }

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      shape: widget.circle ? const CircleBorder() : null,
      padding: widget.circle
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 6),
      fixedSize: widget.circle ? const Size(36, 36) : null,
      // Square-minimum so single-character buttons like "|" or "/" get a
      // finger-friendly hit area, while longer labels expand as needed.
      minimumSize: const Size(36, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 4),
      // Listener observes raw pointer events without entering the gesture
      // arena, so the OutlinedButton's own tap recognizer still runs (giving
      // us the Material ripple) without double-firing the action — we only
      // supply a no-op onPressed so the button stays visually enabled.
      child: Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _stop(),
        onPointerCancel: (_) => _stop(),
        child: OutlinedButton(
          style: style,
          onPressed: () {},
          child: Text(widget.label),
        ),
      ),
    );
  }
}

/// Owns the sticky modifier state and routes virtual-key taps through the
/// terminal. After a single non-modifier key is sent, sticky modifiers
/// auto-clear (the common iOS/PuTTY behaviour — a long-press toggle could
/// be added later if needed).
class ExtraKeysController extends ChangeNotifier
    implements TerminalInputHandler {
  ExtraKeysController(this._delegate);

  final TerminalInputHandler _delegate;
  Terminal? _terminal;

  bool _ctrl = false;
  bool _alt = false;
  bool _shift = false;

  // Snapshot taken at the start of a held key. While a hold is active
  // we reapply these on every repeat instead of using the current
  // sticky state — otherwise the first repeat would consume the
  // modifier and subsequent repeats would be plain (Ctrl+↓ once, then
  // ↓ ↓ ↓ …). endHold() then collapses them back into a single
  // consume, so the "sticky modifier clears on use" contract still
  // holds across the whole hold.
  bool _holding = false;
  bool _heldCtrl = false;
  bool _heldAlt = false;
  bool _heldShift = false;

  bool get ctrl => _ctrl;
  bool get alt => _alt;
  bool get shift => _shift;

  void attach(Terminal terminal) {
    _terminal = terminal;
  }

  void toggleCtrl() {
    _ctrl = !_ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    _alt = !_alt;
    notifyListeners();
  }

  void toggleShift() {
    _shift = !_shift;
    notifyListeners();
  }

  void _consumeModifiers() {
    if (_ctrl || _alt || _shift) {
      _ctrl = false;
      _alt = false;
      _shift = false;
      notifyListeners();
    }
  }

  /// Called at the start of a press-and-hold on an auto-repeat key.
  /// Captures the current sticky modifier state so each repeat during
  /// the hold sees the same modifiers, and suppresses the per-key
  /// auto-clear until [endHold] fires.
  void beginHold() {
    _holding = true;
    _heldCtrl = _ctrl;
    _heldAlt = _alt;
    _heldShift = _shift;
  }

  /// Called on pointer-up/cancel at the end of a held key. Applies the
  /// usual sticky-modifier clear that was deferred during the hold.
  void endHold() {
    if (!_holding) return;
    _holding = false;
    _consumeModifiers();
  }

  // During a hold we reuse the snapshotted modifiers on every call and
  // skip _consumeModifiers; outside a hold we behave as before
  // (apply-then-clear).
  bool get _effCtrl => _holding ? _heldCtrl : _ctrl;
  bool get _effAlt => _holding ? _heldAlt : _alt;
  bool get _effShift => _holding ? _heldShift : _shift;

  void sendKey(TerminalKey key) {
    final t = _terminal;
    if (t == null) return;
    t.keyInput(key, ctrl: _effCtrl, alt: _effAlt, shift: _effShift);
    if (!_holding) _consumeModifiers();
  }

  void sendFKey(int n) {
    const map = <int, TerminalKey>{
      1: TerminalKey.f1,
      2: TerminalKey.f2,
      3: TerminalKey.f3,
      4: TerminalKey.f4,
      5: TerminalKey.f5,
      6: TerminalKey.f6,
      7: TerminalKey.f7,
      8: TerminalKey.f8,
      9: TerminalKey.f9,
      10: TerminalKey.f10,
      11: TerminalKey.f11,
      12: TerminalKey.f12,
    };
    final k = map[n];
    if (k != null) sendKey(k);
  }

  void sendText(String text) {
    final t = _terminal;
    if (t == null) return;
    if (text.length == 1 && (_effCtrl || _effAlt)) {
      t.charInput(text.codeUnitAt(0), ctrl: _effCtrl, alt: _effAlt);
    } else {
      t.textInput(text);
    }
    if (!_holding) _consumeModifiers();
  }

  /// Injected as [Terminal.inputHandler] so sticky modifiers apply to every
  /// soft-keyboard keystroke too — a user can tap Ctrl, then type "a" on the
  /// soft keyboard, and the terminal sees Ctrl+A.
  @override
  String? call(TerminalKeyboardEvent event) {
    final merged = event.copyWith(
      ctrl: event.ctrl || _ctrl,
      alt: event.alt || _alt,
      shift: event.shift || _shift,
    );
    final out = _delegate.call(merged);
    if (out != null) _consumeModifiers();
    return out;
  }
}
