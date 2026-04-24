import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../models/host_preferences.dart';
import '../models/ssh_connection.dart';
import '../services/host_settings_store.dart';
import '../services/session_manager.dart';
import '../widgets/extra_keys_bar.dart';
import '../widgets/terminal_selection_handles.dart';
import 'terminal_settings_page.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.connection});

  final SshConnection connection;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final TerminalController _termCtrl = TerminalController();
  final GlobalKey<TerminalViewState> _viewKey = GlobalKey();

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

  // Touch-to-wheel state for mouse-reporting mode (tmux, less, vim …).
  // Step tuned for tmux defaults: ~50 px per wheel tick feels 1:1.
  static const double _wheelStep = 50;
  double _scrollAccum = 0;
  // Minimum total distance a finger must have moved from its pointer-down
  // position before we start translating movement into wheel events. This
  // suppresses finger drift during a long-press (which would otherwise
  // send wheel-up/down events to tmux, making it enter copy mode or scroll).
  static const double _wheelMoveThreshold = 24;
  Offset? _pointerDownPos;
  bool _wheelArmed = false;

  // ── Freeze / selection state ─────────────────────────────────────────────
  //
  // On long-press (P8), we pause SSH data writes so the terminal buffer is
  // static while xterm builds CellAnchors. The session is un-frozen as soon
  // as the long-press gesture ends (pointer-up), so the terminal never gets
  // stuck regardless of what the user does next. At that moment we snapshot
  // the selected text; a Copy button appears in the AppBar until tapped.

  bool _isFrozen = false;
  // True while the pointer is still down for the long-press gesture itself.
  // Cleared on the first pointer-up so we know when to capture + unfreeze.
  bool _longPressGestureActive = false;
  // Set by the inner Listener when it handles the long-press-end pointer-up
  // so the outer body Listener knows not to dismiss selection for that event.
  bool _skipNextOuterPointerUp = false;

  // Key on the Stack that hosts the terminal + teardrop handles. Used to
  // convert RenderTerminal-local selection coordinates into Stack-local
  // coordinates for Positioned placement of the teardrops.
  final GlobalKey _bodyStackKey = GlobalKey();

  // Captured selected text (set in _captureAndUnfreeze). Non-null while the
  // Copy button is visible in the AppBar.
  String? _capturedText;

  // Fixed endpoints remembered at the start of a teardrop handle drag.
  // Held constant for the entire drag so that re-deriving from the (raw,
  // non-normalized) selection on each update cannot cause drift when the
  // two handles cross.
  CellOffset? _startHandleFixedEnd;
  CellOffset? _endHandleFixedStart;

  @override
  void initState() {
    super.initState();
    _title = widget.connection.name;
    // Rebuild when selection changes so teardrop handles appear / disappear.
    _termCtrl.addListener(_onSelectionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session == null && !_starting && !_failed) {
      _starting = true;
      unawaited(_start());
    }
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
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

  Future<void> _paste() async {
    final terminal = _session?.terminal;
    if (terminal == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    terminal.paste(text);
  }

  Future<void> _copyCaptured() => _copyAndUnfreeze();

  // ── Freeze helpers ────────────────────────────────────────────────────────

  // Called by P8 when xterm recognises the long-press (before selectWord).
  void _onLongPressStart(LongPressStartDetails details, CellOffset cell) {
    final session = _session;
    if (session == null) return;
    session.freeze();
    _isFrozen = true;
    _longPressGestureActive = true;
    _capturedText = null;
    // After the current frame: selectWord (called by xterm right after this
    // callback returns) has had a chance to run. If it did not produce a
    // selection (user long-pressed on whitespace / a separator), back out
    // of selection mode so the user isn't stuck with a frozen terminal and
    // a ✕ button but nothing selected.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isFrozen) return;
      if (_termCtrl.selection == null) {
        _dismissSelection();
      }
    });
  }

  // Called when the pointer that started the long-press is released.
  // Snapshots the current selection into [_capturedText] so the Copy button
  // works, but keeps the session frozen so the user can still drag the
  // teardrop handles to refine the selection before tapping Copy.
  void _snapshotSelection() {
    final sel = _termCtrl.selection;
    final session = _session;
    String? text;
    if (sel != null && session != null) {
      final raw = session.terminal.buffer.getText(sel);
      if (raw.trim().isNotEmpty) text = raw;
    }
    if (mounted) setState(() => _capturedText = text);
  }

  // Copies the most-current selection, clears it, and unfreezes the session.
  // Called when the user taps the Copy button in the AppBar.
  Future<void> _copyAndUnfreeze() async {
    // Re-read from the terminal buffer in case handles were dragged after
    // the initial snapshot.
    final sel = _termCtrl.selection;
    final session = _session;
    String? text = _capturedText;
    if (sel != null && session != null) {
      final raw = session.terminal.buffer.getText(sel);
      if (raw.trim().isNotEmpty) text = raw;
    }
    if (text != null && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (!mounted) return;
    _termCtrl.clearSelection();
    _unfreeze();
    setState(() => _capturedText = null);
    _viewKey.currentState?.requestKeyboard();
  }

  // Dismisses selection mode without copying (e.g. user tapped the terminal).
  void _dismissSelection() {
    // P10: if this dismiss was triggered by a tap on the terminal area,
    // the tap-up that follows will otherwise send a paired mouse-down+up
    // to a mouse-aware remote (tmux, vim…) and put it in a weird state
    // for the next gesture. Swallow that single upcoming mouse event.
    _termCtrl.suppressNextTapMouseEvent = true;
    _termCtrl.clearSelection();
    _unfreeze();
    if (mounted) setState(() => _capturedText = null);
    _viewKey.currentState?.requestKeyboard();
  }

  void _unfreeze() {
    if (!_isFrozen) return;
    _session?.unfreeze();
    _isFrozen = false;
    _longPressGestureActive = false;
  }

  @override
  void dispose() {
    _termCtrl.removeListener(_onSelectionChanged);
    _termCtrl.dispose();
    _unfreeze();
    super.dispose();
  }

  // ── Handle drag callbacks ─────────────────────────────────────────────────

  void _onStartHandlePanStart(DragStartDetails _) {
    // Snapshot the fixed end from the normalized selection so it stays
    // constant throughout the drag even if handles cross.
    _startHandleFixedEnd = _termCtrl.selection?.normalized.end;
  }

  void _onStartHandlePanUpdate(DragUpdateDetails details) {
    final rt = _viewKey.currentState?.renderTerminal;
    final fixedEnd = _startHandleFixedEnd;
    final buf = _session?.terminal.buffer;
    if (rt == null || fixedEnd == null || buf == null) return;
    // Directly set anchors to avoid selectCharacters' conditional +1 on
    // toPosition.x, which would shift fixedEnd by 1 cell whenever the
    // comparison flips. fixedEnd is already an exclusive boundary (one past
    // the last highlighted cell), so it can be used unchanged as the extent.
    final fromCell = rt.getCellOffset(rt.globalToLocal(details.globalPosition));
    _termCtrl.setSelection(
      buf.createAnchorFromOffset(fromCell),
      buf.createAnchorFromOffset(fixedEnd),
    );
    _snapshotSelection();
  }

  void _onStartHandlePanEnd(DragEndDetails _) => _startHandleFixedEnd = null;

  void _onEndHandlePanStart(DragStartDetails _) {
    _endHandleFixedStart = _termCtrl.selection?.normalized.begin;
  }

  void _onEndHandlePanUpdate(DragUpdateDetails details) {
    final rt = _viewKey.currentState?.renderTerminal;
    final fixedStart = _endHandleFixedStart;
    final buf = _session?.terminal.buffer;
    if (rt == null || fixedStart == null || buf == null) return;
    // Add +1 to x so the cell under the finger is included (exclusive-end
    // convention: end.x is the first non-highlighted column).
    final toCell = rt.getCellOffset(rt.globalToLocal(details.globalPosition));
    final toExclusive = CellOffset(toCell.x + 1, toCell.y);
    _termCtrl.setSelection(
      buf.createAnchorFromOffset(fixedStart),
      buf.createAnchorFromOffset(toExclusive),
    );
    _snapshotSelection();
  }

  void _onEndHandlePanEnd(DragEndDetails _) => _endHandleFixedStart = null;

  // Converts a [CellOffset] (in RenderTerminal-local cell space) into a
  // pixel offset in the coordinate system of the body [Stack] hosting
  // both the terminal and the teardrop handles. Returns null if the
  // required render objects haven't been laid out yet.
  Offset? _cellToStackOffset(CellOffset cell) {
    final rt = _viewKey.currentState?.renderTerminal;
    final stackBox =
        _bodyStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (rt == null || stackBox == null || !rt.hasSize || !stackBox.hasSize) {
      return null;
    }
    final localInRt = rt.getOffset(cell) + Offset(0, rt.lineHeight);
    return stackBox.globalToLocal(rt.localToGlobal(localInRt));
  }

  // Builds the Positioned teardrop handles for the current selection.
  // Called from build() when frozen + hasSelection. Computes positions
  // directly from RenderTerminal so we don't depend on LayerLink / the
  // CompositedTransformFollower anchor math.
  List<Widget> _buildHandles() {
    final sel = _termCtrl.selection;
    if (sel == null) return const [];
    final startStack = _cellToStackOffset(sel.normalized.begin);
    final endStack = _cellToStackOffset(sel.normalized.end);
    if (startStack == null || endStack == null) {
      // Render objects not ready yet — schedule a rebuild after layout so
      // the handles appear on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return const [];
    }
    const size = TerminalSelectionHandle.size;
    return [
      // Start handle: tip (top-right corner) sits at the selection start.
      Positioned(
        left: startStack.dx - size,
        top: startStack.dy,
        child: TerminalSelectionHandle(
          isStart: true,
          onPanStart: _onStartHandlePanStart,
          onPanUpdate: _onStartHandlePanUpdate,
          onPanEnd: _onStartHandlePanEnd,
        ),
      ),
      // End handle: tip (top-left corner) sits at the selection end.
      Positioned(
        left: endStack.dx,
        top: endStack.dy,
        child: TerminalSelectionHandle(
          isStart: false,
          onPanStart: _onEndHandlePanStart,
          onPanUpdate: _onEndHandlePanUpdate,
          onPanEnd: _onEndHandlePanEnd,
        ),
      ),
    ];
  }

  // ── Pointer / wheel passthrough ───────────────────────────────────────────

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
    if (!_reportsMouse) return;
    // Don't emit wheel events while selecting or frozen.
    if (_termCtrl.selection != null || _isFrozen) return;
    // Require the finger to have moved past a threshold from its initial
    // pointer-down position before we start emitting wheel events. Small
    // finger drift while holding for a long-press must NOT turn into
    // wheel events, or tmux ends up in copy mode / scrolled right as the
    // long-press is about to fire — breaking the selection.
    if (!_wheelArmed) {
      final start = _pointerDownPos;
      if (start == null) return;
      final dx = event.localPosition.dx - start.dx;
      final dy = event.localPosition.dy - start.dy;
      if (dx * dx + dy * dy < _wheelMoveThreshold * _wheelMoveThreshold) {
        return;
      }
      _wheelArmed = true;
    }
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

  void _onPointerUp(PointerUpEvent event) {
    _scrollAccum = 0;
    if (!_isFrozen) return;
    if (_longPressGestureActive) {
      // Long-press gesture ended: snapshot the selection for the Copy button
      // but keep the session frozen so the user can drag the teardrop handles
      // to refine the selection before tapping Copy.
      _longPressGestureActive = false;
      // Tell the outer body Listener not to dismiss for this same pointer-up.
      _skipNextOuterPointerUp = true;
      _snapshotSelection();
    } else {
      // User tapped the terminal while in selection mode (e.g. to dismiss).
      _dismissSelection();
    }
  }

  // Outer body Listener — catches taps on the ExtraKeysBar and any other
  // area outside the terminal's own Listener. Fires after the inner one.
  void _onBodyPointerUp(PointerUpEvent event) {
    if (_skipNextOuterPointerUp) {
      _skipNextOuterPointerUp = false;
      return;
    }
    if (!_isFrozen) return;
    // Don't dismiss while a teardrop handle drag is in progress (the
    // GestureDetector on the handle fires onPanEnd AFTER Listeners see
    // the pointer-up, so the fixed-endpoint fields are still non-null here).
    if (_startHandleFixedEnd != null || _endHandleFixedStart != null) return;
    _dismissSelection();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _scrollAccum = 0;
    _longPressGestureActive = false;
    if (_isFrozen) _dismissSelection();
  }

  // ── Style ─────────────────────────────────────────────────────────────────

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
    final usableWidth = (width - 8).clamp(1, double.infinity);
    final fontSize = usableWidth / (cols * advancePerPoint);
    final clamped = fontSize.clamp(6.0, 48.0);
    return TerminalStyle(fontSize: clamped);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final terminal = session?.terminal ?? _pending;
    final keys = session?.keys;
    final prefs = context
        .watch<HostSettingsStore>()
        .get(widget.connection.host);
    final hasSelection = _termCtrl.selection != null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_title, overflow: TextOverflow.ellipsis),
        actions: [
          // Gate on hasSelection (not _isFrozen): long-presses that land on
          // whitespace set _isFrozen briefly and then auto-dismiss, which
          // otherwise causes the ✕ to flicker on for a single frame.
          if (_isFrozen && hasSelection) ...[
            if (_capturedText != null)
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy selection',
                onPressed: _copyCaptured,
              ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Dismiss selection',
              onPressed: _dismissSelection,
            ),
          ],
          PopupMenuButton<_MenuAction>(
            icon: const Icon(Icons.menu),
            onSelected: (a) {
              switch (a) {
                case _MenuAction.paste:
                  _paste();
                  break;
                case _MenuAction.settings:
                  _openSettings();
                  break;
                case _MenuAction.disconnect:
                  _disconnect();
                  break;
              }
            },
            itemBuilder: (_) => [
              if (session != null)
                const PopupMenuItem(
                  value: _MenuAction.paste,
                  child: ListTile(
                    leading: Icon(Icons.content_paste),
                    title: Text('Paste'),
                  ),
                ),
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
      body: Listener(
        onPointerUp: _onBodyPointerUp,
        child: Stack(
        key: _bodyStackKey,
        children: [
          Column(
            children: [
              Expanded(
                child: Listener(
                  onPointerDown: (e) {
                    _pointerDownPos = e.localPosition;
                    _wheelArmed = false;
                    _scrollAccum = 0;
                  },
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerCancel,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final style = _styleFor(constraints.maxWidth, prefs);
                      return TerminalView(
                        terminal,
                        key: _viewKey,
                        controller: _termCtrl,
                        autofocus: true,
                        backgroundOpacity: 1,
                        padding: const EdgeInsets.all(4),
                        deleteDetection: true,
                        simulateScroll: true,
                        handleAltBufferTouchScroll: false,
                        suppressInternalSelectionGestures: false,
                        onLongPressStart:
                            session != null ? _onLongPressStart : null,
                        textStyle: style,
                      );
                    },
                  ),
                ),
              ),
              if (keys != null) ExtraKeysBar(controller: keys),
            ],
          ),
          // Teardrop selection handles — visible only while frozen + selected.
          if (hasSelection && _isFrozen) ..._buildHandles(),
        ],
        ),
      ),
    );
  }
}

enum _MenuAction { paste, settings, disconnect }
