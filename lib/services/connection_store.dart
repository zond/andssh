import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/ssh_connection.dart';
import 'secret_store.dart';

/// Stores connection metadata (non-secret) in a JSON file under the app's
/// documents dir. Secrets are delegated to [SecretStore].
class ConnectionStore extends ChangeNotifier {
  ConnectionStore(this._secrets);

  final SecretStore _secrets;
  final List<SshConnection> _connections = [];
  bool _loaded = false;

  List<SshConnection> get connections => List.unmodifiable(_connections);
  bool get isLoaded => _loaded;

  SshConnection? byId(String id) {
    for (final c in _connections) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/connections.json');
  }

  Future<void> load() async {
    final f = await _file();
    if (await f.exists()) {
      final raw = await f.readAsString();
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _connections
          ..clear()
          ..addAll(decoded.map(
            (e) => SshConnection.fromJson(e as Map<String, dynamic>),
          ));
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final f = await _file();
    await f.writeAsString(
      jsonEncode(_connections.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> upsert(SshConnection conn, {SshCredentials? creds}) async {
    final idx = _connections.indexWhere((c) => c.id == conn.id);
    if (idx >= 0) {
      _connections[idx] = conn;
    } else {
      _connections.add(conn);
    }
    await _persist();
    if (creds != null) {
      await _secrets.save(conn.id, creds);
    }
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _connections.removeWhere((c) => c.id == id);
    await _persist();
    await _secrets.delete(id);
    notifyListeners();
  }

  /// Returns the chain [target, jump1, jump2, ...] — the outermost jump host
  /// is last. Breaks on missing references or cycles.
  List<SshConnection> resolveJumpChain(SshConnection target) {
    final chain = <SshConnection>[target];
    final visited = <String>{target.id};
    var current = target;
    while (current.jumpHostId != null) {
      final next = byId(current.jumpHostId!);
      if (next == null || !visited.add(next.id)) break;
      chain.add(next);
      current = next;
    }
    return chain;
  }
}
