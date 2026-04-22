import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ssh_connection.dart';
import '../services/connection_store.dart';

class ConnectionFormPage extends StatefulWidget {
  const ConnectionFormPage({super.key, this.existing});

  final SshConnection? existing;

  @override
  State<ConnectionFormPage> createState() => _ConnectionFormPageState();
}

class _ConnectionFormPageState extends State<ConnectionFormPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();

  late SshAuthMethod _authMethod;
  String? _jumpHostId;
  bool _replaceCredentials = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: e?.port.toString() ?? '22');
    _user = TextEditingController(text: e?.username ?? '');
    _authMethod = e?.authMethod ?? SshAuthMethod.password;
    _jumpHostId = e?.jumpHostId;
    _replaceCredentials = e == null; // new connection ⇒ must enter creds
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final store = context.read<ConnectionStore>();
    try {
      final id = widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString();
      final conn = SshConnection(
        id: id,
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _user.text.trim(),
        authMethod: _authMethod,
        jumpHostId: _jumpHostId,
      );
      final creds = _replaceCredentials
          ? SshCredentials(
              password: _authMethod == SshAuthMethod.password
                  ? _password.text
                  : null,
              privateKey: _authMethod == SshAuthMethod.privateKey
                  ? _privateKey.text
                  : null,
              privateKeyPassphrase: _authMethod == SshAuthMethod.privateKey &&
                      _passphrase.text.isNotEmpty
                  ? _passphrase.text
                  : null,
            )
          : null;
      await store.upsert(conn, creds: creds);
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $err')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ConnectionStore>();
    final jumpCandidates = store.connections
        .where((c) => c.id != widget.existing?.id)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New connection' : 'Edit'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saving ? null : _submit,
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Display name'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              TextFormField(
                controller: _host,
                decoration: const InputDecoration(labelText: 'Host'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              TextFormField(
                controller: _port,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final p = int.tryParse(v?.trim() ?? '');
                  if (p == null || p <= 0 || p > 65535) return 'Invalid port';
                  return null;
                },
              ),
              TextFormField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<SshAuthMethod>(
                initialValue: _authMethod,
                decoration:
                    const InputDecoration(labelText: 'Authentication'),
                items: const [
                  DropdownMenuItem(
                    value: SshAuthMethod.password,
                    child: Text('Password'),
                  ),
                  DropdownMenuItem(
                    value: SshAuthMethod.privateKey,
                    child: Text('Private key'),
                  ),
                ],
                onChanged: (v) => setState(() => _authMethod = v!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: _jumpHostId,
                decoration: const InputDecoration(
                  labelText: 'Jump host (ProxyJump)',
                  helperText: 'Optional. Select another saved connection '
                      'to tunnel through.',
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('— none —'),
                  ),
                  ...jumpCandidates.map(
                    (c) => DropdownMenuItem(
                      value: c.id,
                      child: Text('${c.name} (${c.username}@${c.host})'),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _jumpHostId = v),
              ),
              const SizedBox(height: 24),
              if (widget.existing != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Replace stored credentials'),
                  subtitle: const Text(
                    'Enabling this will prompt for biometrics when saving.',
                  ),
                  value: _replaceCredentials,
                  onChanged: (v) => setState(() => _replaceCredentials = v),
                ),
              if (_replaceCredentials) ..._credentialFields(),
              const SizedBox(height: 24),
              if (_saving) const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _credentialFields() {
    switch (_authMethod) {
      case SshAuthMethod.password:
        return [
          TextFormField(
            controller: _password,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            validator: (v) =>
                (v == null || v.isEmpty) ? 'Required' : null,
          ),
        ];
      case SshAuthMethod.privateKey:
        return [
          TextFormField(
            controller: _privateKey,
            decoration: const InputDecoration(
              labelText: 'Private key (PEM)',
              hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n…',
            ),
            minLines: 4,
            maxLines: 10,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          TextFormField(
            controller: _passphrase,
            decoration: const InputDecoration(
              labelText: 'Key passphrase (optional)',
            ),
            obscureText: true,
          ),
        ];
    }
  }
}
