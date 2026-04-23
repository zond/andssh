import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// A virtual-keyboard row for keys that Android's soft keyboard doesn't
/// expose (arrows, Home/End, PgUp/PgDn, F-keys, Tab, Esc) plus sticky
/// modifier toggles for Ctrl/Alt/Shift so combos like Ctrl+A (the default
/// tmux prefix) work with single-character keys from the soft keyboard.
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
            child: SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                children: [
                  _arrow('↑', () => controller.sendKey(TerminalKey.arrowUp)),
                  _arrow(
                      '↓', () => controller.sendKey(TerminalKey.arrowDown)),
                  _arrow(
                      '←', () => controller.sendKey(TerminalKey.arrowLeft)),
                  _arrow(
                      '→', () => controller.sendKey(TerminalKey.arrowRight)),
                  const SizedBox(width: 4),
                  _toggle('Ctrl', controller.ctrl,
                      () => controller.toggleCtrl()),
                  _toggle(
                      'Alt', controller.alt, () => controller.toggleAlt()),
                  _toggle('Shift', controller.shift,
                      () => controller.toggleShift()),
                  const SizedBox(width: 4),
                  _key('Esc', () => controller.sendKey(TerminalKey.escape)),
                  _key('Tab', () => controller.sendKey(TerminalKey.tab)),
                  _key('|', () => controller.sendText('|')),
                  _key('/', () => controller.sendText('/')),
                  _key('\\', () => controller.sendText('\\')),
                  _key('~', () => controller.sendText('~')),
                  _key('-', () => controller.sendText('-')),
                  _key('_', () => controller.sendText('_')),
                  const SizedBox(width: 4),
                  _key('Home', () => controller.sendKey(TerminalKey.home)),
                  _key('End', () => controller.sendKey(TerminalKey.end)),
                  _key('PgUp', () => controller.sendKey(TerminalKey.pageUp)),
                  _key('PgDn',
                      () => controller.sendKey(TerminalKey.pageDown)),
                  _key('Ins', () => controller.sendKey(TerminalKey.insert)),
                  _key('Del', () => controller.sendKey(TerminalKey.delete)),
                  const SizedBox(width: 4),
                  for (int i = 1; i <= 12; i++)
                    _key('F$i', () => controller.sendFKey(i)),
                ],
              ),
            ),
          ),
        );
      },
    );
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 4),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          // Square-minimum so single-character buttons like "|" or "/"
          // get a finger-friendly hit area, while longer labels expand
          // horizontally as needed.
          minimumSize: const Size(36, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }

  Widget _arrow(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 4),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          fixedSize: const Size(36, 36),
          minimumSize: const Size(36, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onTap,
        child: Text(label),
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

  void sendKey(TerminalKey key) {
    final t = _terminal;
    if (t == null) return;
    t.keyInput(key, ctrl: _ctrl, alt: _alt, shift: _shift);
    _consumeModifiers();
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
    if (text.length == 1 && (_ctrl || _alt)) {
      t.charInput(text.codeUnitAt(0), ctrl: _ctrl, alt: _alt);
    } else {
      t.textInput(text);
    }
    _consumeModifiers();
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
