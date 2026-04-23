import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../models/ssh_connection.dart';
import '../services/secret_store.dart';
import '../services/ssh_connector.dart';
import '../widgets/extra_keys_bar.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.connection});

  final SshConnection connection;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  late final ExtraKeysController _keys;
  late final Terminal _terminal;
  final TerminalController _termCtrl = TerminalController();

  SshClientBundle? _bundle;
  SSHSession? _session;
  String _title = '';
  String _status = 'Connecting…';
  bool _connected = false;
  bool _failed = false;

  late final SecretStore _secrets;
  late final SshConnector _connector;

  @override
  void initState() {
    super.initState();
    _keys = ExtraKeysController(defaultInputHandler);
    _terminal = Terminal(
      maxLines: 10000,
      inputHandler: _keys,
    );
    _keys.attach(_terminal);
    _title = widget.connection.name;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _secrets = context.read<SecretStore>();
    _connector = context.read<SshConnector>();
    if (_bundle == null && !_failed) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    try {
      final creds = await _secrets.load(widget.connection.id);
      if (creds == null) {
        throw StateError('No stored credentials for this connection.');
      }
      final bundle = await _connector.connect(
        target: widget.connection,
        targetCreds: creds,
        onProgress: (line) => _terminal.write('$line\r\n'),
      );
      _bundle = bundle;

      final session = await bundle.target.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );
      _session = session;

      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);
      _terminal.onTitleChange = (t) => setState(() => _title = t);
      _terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h, pw, ph);
      _terminal.onOutput = (data) => session.write(utf8.encode(data));

      session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);
      session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);
      unawaited(session.done.then((_) {
        if (!mounted) return;
        setState(() {
          _status = 'Disconnected';
          _connected = false;
        });
        _terminal.write('\r\n[connection closed]\r\n');
      }));

      if (!mounted) return;
      setState(() {
        _status = 'Connected';
        _connected = true;
      });
    } catch (e, st) {
      developer.log(
        'connect failed',
        name: 'andssh',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _status = 'Failed: $e';
        _failed = true;
      });
      _terminal.write('\r\nConnection failed: $e\r\n');
    }
  }

  @override
  void dispose() {
    _session?.close();
    _bundle?.close();
    _termCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_title, overflow: TextOverflow.ellipsis),
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
            child: TerminalView(
              _terminal,
              controller: _termCtrl,
              autofocus: true,
              backgroundOpacity: 1,
              padding: const EdgeInsets.all(4),
              deleteDetection: true,
            ),
          ),
          ExtraKeysBar(controller: _keys),
        ],
      ),
    );
  }
}
