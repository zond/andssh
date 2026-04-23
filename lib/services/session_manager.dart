import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../models/ssh_connection.dart';
import '../widgets/extra_keys_bar.dart';
import 'secret_store.dart';
import 'ssh_connector.dart';

void _log(String msg) => debugPrint('andssh: $msg');

/// A live SSH session: the [Terminal] view state, the underlying
/// [SshClientBundle]/[SSHSession], and everything needed to keep it
/// running across page navigation. Owned by [SessionManager], not by any
/// widget.
class ActiveSession {
  ActiveSession({
    required this.connection,
    required this.terminal,
    required this.keys,
    required this.bundle,
    required this.sshSession,
    required this.stdoutSub,
    required this.stderrSub,
    required this.doneSub,
  });

  final SshConnection connection;
  final Terminal terminal;
  final ExtraKeysController keys;
  final SshClientBundle bundle;
  final SSHSession sshSession;
  final StreamSubscription<String> stdoutSub;
  final StreamSubscription<String> stderrSub;
  final StreamSubscription<void> doneSub;

  Future<void> close() async {
    await stdoutSub.cancel();
    await stderrSub.cancel();
    await doneSub.cancel();
    sshSession.close();
    await bundle.close();
  }
}

/// Holds all currently-open SSH sessions keyed by connection id, and
/// notifies listeners when the active set changes so the UI (and
/// notification) can update.
class SessionManager extends ChangeNotifier {
  SessionManager(this._secrets, this._connector);

  final SecretStore _secrets;
  final SshConnector _connector;
  final Map<String, ActiveSession> _sessions = {};

  ActiveSession? get(String id) => _sessions[id];
  bool hasSession(String id) => _sessions.containsKey(id);
  List<ActiveSession> get sessions => List.unmodifiable(_sessions.values);

  /// Returns the existing session if one is already open; otherwise
  /// unlocks credentials (which prompts biometrics), dials the chain,
  /// opens a shell, and registers the new session.
  Future<ActiveSession> openOrReuse(
    SshConnection connection, {
    void Function(String line)? onProgress,
  }) async {
    final existing = _sessions[connection.id];
    if (existing != null) {
      onProgress?.call('Attached to existing session.');
      return existing;
    }

    final creds = await _secrets.load(connection.id);
    if (creds == null) {
      throw StateError('No stored credentials for this connection.');
    }
    final bundle = await _connector.connect(
      target: connection,
      targetCreds: creds,
      onProgress: onProgress,
    );

    final keys = ExtraKeysController(defaultInputHandler);
    final terminal = Terminal(
      maxLines: 10000,
      inputHandler: keys,
    );
    keys.attach(terminal);

    final sshSession = await bundle.target.shell(
      pty: SSHPtyConfig(
        type: 'xterm-256color',
        width: terminal.viewWidth,
        height: terminal.viewHeight,
      ),
    );

    terminal.buffer.clear();
    terminal.buffer.setCursor(0, 0);
    terminal.onResize =
        (w, h, pw, ph) => sshSession.resizeTerminal(w, h, pw, ph);
    terminal.onOutput = (data) {
      // Log escape-sequence traffic so mouse / cursor-key / function-key
      // mishaps are visible in `adb logcat`. Plain typed bytes are
      // skipped to keep the log usable.
      if (data.contains('\x1b')) {
        final visible = data
            .replaceAll('\x1b', '\\e')
            .replaceAll('\r', '\\r')
            .replaceAll('\n', '\\n');
        _log('→ ssh: $visible');
      }
      sshSession.write(utf8.encode(data));
    };

    final stdoutSub = sshSession.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    final stderrSub = sshSession.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    final doneSub = sshSession.done.asStream().listen((_) {
      terminal.write('\r\n[connection closed]\r\n');
      _log('session ${connection.id} ended remotely');
      _removeAndNotify(connection.id);
    });

    final session = ActiveSession(
      connection: connection,
      terminal: terminal,
      keys: keys,
      bundle: bundle,
      sshSession: sshSession,
      stdoutSub: stdoutSub,
      stderrSub: stderrSub,
      doneSub: doneSub,
    );
    _sessions[connection.id] = session;
    notifyListeners();
    return session;
  }

  Future<void> disconnect(String id) async {
    final s = _sessions.remove(id);
    if (s == null) return;
    _log('disconnect session $id');
    await s.close();
    notifyListeners();
  }

  Future<void> _removeAndNotify(String id) async {
    if (_sessions.remove(id) == null) return;
    notifyListeners();
  }

  Future<void> disconnectAll() async {
    final copy = List.of(_sessions.values);
    _sessions.clear();
    notifyListeners();
    for (final s in copy) {
      await s.close();
    }
  }
}
