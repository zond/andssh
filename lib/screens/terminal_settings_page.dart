import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/host_preferences.dart';
import '../services/host_settings_store.dart';

/// Edits the per-host terminal settings. Changes are persisted on save
/// so any open session with that host rebuilds immediately.
class TerminalSettingsPage extends StatefulWidget {
  const TerminalSettingsPage({super.key, required this.host});

  final String host;

  @override
  State<TerminalSettingsPage> createState() => _TerminalSettingsPageState();
}

class _TerminalSettingsPageState extends State<TerminalSettingsPage> {
  final _columns = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Provider / InheritedWidget reads belong here, not initState. Seed
    // the text field once on the first didChangeDependencies; subsequent
    // inherited-widget changes (theme, locale, media-query) must not
    // re-overwrite whatever the user is typing.
    if (_seeded) return;
    _seeded = true;
    final store = context.read<HostSettingsStore>();
    final current = store.get(widget.host).preferredColumns;
    _columns.text = current?.toString() ?? '';
  }

  @override
  void dispose() {
    _columns.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final store = context.read<HostSettingsStore>();
    final raw = _columns.text.trim();
    final cols = raw.isEmpty ? null : int.parse(raw);
    await store.update(
      widget.host,
      HostPreferences(preferredColumns: cols),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings · ${widget.host}'),
        actions: [
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Applies to every connection to "${widget.host}".',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _columns,
              decoration: const InputDecoration(
                labelText: 'Column count',
                helperText: 'Leave blank to auto-fit. '
                    'Typical values: 80, 100, 132, 160.',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                final n = int.tryParse(v.trim());
                if (n == null || n < 20 || n > 400) {
                  return 'Enter a number between 20 and 400, or leave blank';
                }
                return null;
              },
            ),
          ],
        ),
      ),
    );
  }
}
