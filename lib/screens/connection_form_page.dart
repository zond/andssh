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
  // Editable host-key fields. The stored format is lowercase hex with
  // no separators; the text box accepts and normalises several
  // formats (with colons, with "MD5:" prefix, raw hex). Either field
  // empty means "no pin" — the next connect will TOFU and populate.
  late final TextEditingController _hostKeyType;
  late final TextEditingController _hostKeyFp;

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
    _hostKeyType = TextEditingController(text: e?.hostKeyType ?? '');
    _hostKeyFp = TextEditingController(
      text: e?.hostKeyFingerprint == null
          ? ''
          : _formatFingerprint(e!.hostKeyFingerprint!),
    );
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
    _hostKeyType.dispose();
    _hostKeyFp.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final store = context.read<ConnectionStore>();
    try {
      final id = widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString();
      // Normalise on save: strip "MD5:" prefix, colons, whitespace; store
      // as lowercase hex. Either field empty → stored as null (unpinned).
      // Validation happens in _hostKeyFpValidator during the form's
      // validate() call above.
      final typeText = _hostKeyType.text.trim();
      final fpText = _hostKeyFp.text;
      final normFp = _normalizeFingerprint(fpText);
      final conn = SshConnection(
        id: id,
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _user.text.trim(),
        authMethod: _authMethod,
        jumpHostId: _jumpHostId,
        hostKeyType: typeText.isEmpty ? null : typeText,
        hostKeyFingerprint: normFp,
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
              _buildHostKeyBlock(context),
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

  Widget _buildHostKeyBlock(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Host key (optional)', style: textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Leave blank to trust-on-first-connect. If both fields are '
          'set, the next connect fails with a prompt if the server '
          'presents a different key.',
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _hostKeyType,
          decoration: const InputDecoration(
            labelText: 'Type',
            hintText: 'e.g. ssh-ed25519, ssh-rsa',
          ),
          autocorrect: false,
          enableSuggestions: false,
        ),
        TextFormField(
          controller: _hostKeyFp,
          decoration: const InputDecoration(
            labelText: 'MD5 fingerprint',
            hintText: 'ab:cd:…  /  MD5:ab:cd:…  /  raw hex',
          ),
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace'),
          validator: _hostKeyFpValidator,
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.clear, size: 18),
            label: const Text('Clear (re-pin on next connect)'),
            onPressed: () {
              _hostKeyType.clear();
              _hostKeyFp.clear();
            },
          ),
        ),
      ],
    );
  }

  /// Accepts several user-friendly shapes for the fingerprint:
  ///   * `ab:cd:ef:…` (ssh-keygen's default)
  ///   * `MD5:ab:cd:…` (with the `MD5:` prefix OpenSSH prints)
  ///   * `abcdef…` (raw hex)
  /// After stripping prefix / colons / spaces the remaining string must
  /// be 32 lowercase hex digits (16-byte MD5). Empty input is accepted
  /// (means "no pin").
  static String? _hostKeyFpValidator(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final hex = _stripFingerprint(v);
    if (hex.length != 32) {
      return 'Expected 32 hex chars after stripping colons / MD5: prefix';
    }
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(hex)) {
      return 'Non-hex characters in fingerprint';
    }
    return null;
  }

  static String? _normalizeFingerprint(String v) {
    final hex = _stripFingerprint(v);
    return hex.isEmpty ? null : hex;
  }

  static String _stripFingerprint(String v) {
    var s = v.trim().toLowerCase();
    if (s.startsWith('md5:')) s = s.substring(4);
    return s.replaceAll(RegExp(r'[:\-\s]'), '');
  }

  /// Formats a stored lowercase-hex fingerprint for display as
  /// `ab:cd:ef:…` — matches the ssh-keygen default output.
  static String _formatFingerprint(String hex) {
    final sb = StringBuffer();
    for (var i = 0; i < hex.length; i += 2) {
      if (i > 0) sb.write(':');
      sb.write(hex.substring(i, i + 2));
    }
    return sb.toString();
  }

  List<Widget> _credentialFields() {
    switch (_authMethod) {
      case SshAuthMethod.password:
        return [
          TextFormField(
            controller: _password,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            // Don't feed secrets to the IME's suggestion cache /
            // predictive autocorrect / clipboard-suggestion bar.
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
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
            // Same reasoning as the password field; PEM isn't `obscureText`
            // because users need to paste/edit it, but we still want no
            // IME suggestions / autocorrect on private key material.
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.multiline,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          TextFormField(
            controller: _passphrase,
            decoration: const InputDecoration(
              labelText: 'Key passphrase (optional)',
            ),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
          ),
        ];
    }
  }
}
