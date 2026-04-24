import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/host_preferences.dart';

/// Per-host preferences (keyed by `SshConnection.host`). Persisted in the
/// app's documents dir alongside connections.json.
class HostSettingsStore extends ChangeNotifier {
  final Map<String, HostPreferences> _prefs = {};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  HostPreferences get(String host) =>
      _prefs[host] ?? const HostPreferences();

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/host_settings.json');
  }

  Future<void> load() async {
    final f = await _file();
    if (await f.exists()) {
      final raw = await f.readAsString();
      if (raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw) as Map<String, dynamic>;
          _prefs
            ..clear()
            ..addEntries(decoded.entries.map(
              (e) => MapEntry(
                e.key,
                HostPreferences.fromJson(e.value as Map<String, dynamic>),
              ),
            ));
        } catch (e) {
          debugPrint('andssh: host_settings.json parse failed: $e');
          _prefs.clear();
        }
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(_prefs.map((k, v) => MapEntry(k, v.toJson()))),
      flush: true,
    );
    await tmp.rename(f.path);
  }

  Future<void> update(String host, HostPreferences prefs) async {
    if (prefs.isEmpty) {
      _prefs.remove(host);
    } else {
      _prefs[host] = prefs;
    }
    await _persist();
    notifyListeners();
  }
}
