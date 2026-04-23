import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../models/host_preferences.dart';
import '../models/ssh_connection.dart';
import '../services/host_settings_store.dart';
import '../services/session_manager.dart';
import '../widgets/extra_keys_bar.dart';
import 'terminal_settings_page.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.connection});

  final SshConnection connection;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final TerminalController _termCtrl = TerminalController();

  // One-shot Terminal used only to show progress / error text before the
  // real session attaches. Once [_session] is set, [_session.terminal]
  // takes over.
  final Terminal _pending = Terminal(maxLines: 500);

  ActiveSession? _session;
  String _title = '';
  String _status = 'Connecting…';
  bool _connected = false;
  bool _failed = false;
  bool _starting = false;

  // Used to translate finger drags to mouse-wheel events while the
  // remote program is in mouse-reporting mode (tmux, less, vim, ...).
  // In plain shell xterm's built-in Scrollable handles the touch drag
  // directly for scrollback — we skip emitting wheel events there.
  //
  // Step tuned so finger motion roughly tracks the scrolled content at
  // tmux defaults (3 lines per wheel tick, ~17 px per line on typical
  // Android density → ~50 px per tick for 1:1 feel).
  static const double _wheelStep = 50;
  double _scrollAccum = 0;

  @override
  void initState() {
    super.initState();
    _title = widget.connection.name;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session == null && !_starting && !_failed) {
      _starting = true;
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    final manager = context.read<SessionManager>();
    try {
      final existing = manager.get(widget.connection.id);
      if (existing != null) {
        _attach(existing);
        return;
      }
      final s = await manager.openOrReuse(
        widget.connection,
        onProgress: (line) => _pending.write('$line\r\n'),
      );
      if (!mounted) return;
      _attach(s);
    } catch (e, st) {
      developer.log('connect failed',
          name: 'andssh', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _status = 'Failed: $e';
        _failed = true;
      });
      _pending.write('\r\nConnection failed: $e\r\n');
    }
  }

  void _attach(ActiveSession s) {
    s.terminal.onTitleChange = (t) {
      if (mounted) setState(() => _title = t);
    };
    setState(() {
      _session = s;
      _status = 'Connected';
      _connected = true;
    });
  }

  Future<void> _disconnect() async {
    final manager = context.read<SessionManager>();
    await manager.disconnect(widget.connection.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalSettingsPage(host: widget.connection.host),
      ),
    );
  }

  @override
  void dispose() {
    // Intentionally does NOT close the session — the SessionManager owns
    // it. The user goes back, the connection stays alive.
    _termCtrl.dispose();
    super.dispose();
  }

  bool get _reportsMouse {
    final t = _session?.terminal;
    if (t == null) return false;
    return t.mouseMode != MouseMode.none &&
        t.mouseMode != MouseMode.clickOnly;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    final session = _session;
    if (session == null) return;
    // Only hijack touch-to-wheel when the remote program wants mouse
    // events. In plain shell, let xterm's native Scrollable scroll the
    // local scrollback.
    if (!_reportsMouse) return;
    _scrollAccum += event.delta.dy;
    while (_scrollAccum.abs() >= _wheelStep) {
      final isWheelUp = _scrollAccum > 0;
      _scrollAccum += isWheelUp ? -_wheelStep : _wheelStep;
      session.terminal.mouseInput(
        isWheelUp
            ? TerminalMouseButton.wheelUp
            : TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        const CellOffset(0, 0),
      );
    }
  }

  // Compute the terminal text style so a requested column count fits the
  // given pixel width. Falls back to xterm's default style when the user
  // hasn't set a column preference for this host.
  TerminalStyle _styleFor(double width, HostPreferences prefs) {
    final cols = prefs.preferredColumns;
    if (cols == null || cols <= 0 || width <= 0) {
      return const TerminalStyle();
    }
    const refSize = 100.0;
    const refStyle = TerminalStyle(fontSize: refSize);
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: refStyle.toTextStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    final advancePerPoint = painter.width / refSize;
    // Padding inside TerminalView is 4px left/right (EdgeInsets.all(4)).
    final usableWidth = (width - 8).clamp(1, double.infinity);
    final fontSize = usableWidth / (cols * advancePerPoint);
    // Clamp so we don't end up with pixel-sized text on weird layouts.
    final clamped = fontSize.clamp(6.0, 48.0);
    return TerminalStyle(fontSize: clamped);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final terminal = session?.terminal ?? _pending;
    final keys = session?.keys;
    final prefs = context
        .watch<HostSettingsStore>()
        .get(widget.connection.host);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_title, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<_MenuAction>(
            icon: const Icon(Icons.menu),
            onSelected: (a) {
              switch (a) {
                case _MenuAction.settings:
                  _openSettings();
                  break;
                case _MenuAction.disconnect:
                  _disconnect();
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _MenuAction.settings,
                child: ListTile(
                  leading: Icon(Icons.settings),
                  title: Text('Settings'),
                ),
              ),
              if (session != null)
                const PopupMenuItem(
                  value: _MenuAction.disconnect,
                  child: ListTile(
                    leading: Icon(Icons.link_off),
                    title: Text('Disconnect'),
                  ),
                ),
            ],
          ),
        ],
        bottom: _connected
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Container(
                  width: double.infinity,
                  color: _failed ? Colors.red.shade900 : Colors.amber.shade900,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 2),
                  child: Text(
                    _status,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Listener(
              onPointerMove: _onPointerMove,
              onPointerUp: (_) => _scrollAccum = 0,
              onPointerCancel: (_) => _scrollAccum = 0,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final style = _styleFor(constraints.maxWidth, prefs);
                  return TerminalView(
                    terminal,
                    controller: _termCtrl,
                    autofocus: true,
                    backgroundOpacity: 1,
                    padding: const EdgeInsets.all(4),
                    deleteDetection: true,
                    simulateScroll: true,
                    textStyle: style,
                  );
                },
              ),
            ),
          ),
          if (keys != null) ExtraKeysBar(controller: keys),
        ],
      ),
    );
  }
}

enum _MenuAction { settings, disconnect }
