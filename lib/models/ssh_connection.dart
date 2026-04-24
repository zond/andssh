enum SshAuthMethod { password, privateKey }

class SshConnection {
  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;

  /// Optional id of another saved [SshConnection] to use as a jump host
  /// (ProxyJump). The jump host's own `jumpHostId` is followed recursively
  /// so arbitrarily long chains are supported.
  final String? jumpHostId;

  /// SSH host-key type (e.g. `ssh-rsa`, `ssh-ed25519`) pinned after the
  /// first successful connection. `null` means "not yet pinned" — the
  /// next connect trusts-on-first-use, captures the fingerprint, and
  /// stores it via [copyWith].
  final String? hostKeyType;

  /// MD5 fingerprint of the pinned host key as a lowercase hex string
  /// (no separators). Compared byte-for-byte against the fingerprint
  /// dartssh2 reports on each connect; a mismatch is flagged to the UI.
  final String? hostKeyFingerprint;

  const SshConnection({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.jumpHostId,
    this.hostKeyType,
    this.hostKeyFingerprint,
  });

  SshConnection copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    SshAuthMethod? authMethod,
    String? jumpHostId,
    bool clearJumpHost = false,
    String? hostKeyType,
    String? hostKeyFingerprint,
    bool clearHostKey = false,
  }) {
    return SshConnection(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      jumpHostId: clearJumpHost ? null : (jumpHostId ?? this.jumpHostId),
      hostKeyType: clearHostKey ? null : (hostKeyType ?? this.hostKeyType),
      hostKeyFingerprint: clearHostKey
          ? null
          : (hostKeyFingerprint ?? this.hostKeyFingerprint),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        if (jumpHostId != null) 'jumpHostId': jumpHostId,
        if (hostKeyType != null) 'hostKeyType': hostKeyType,
        if (hostKeyFingerprint != null) 'hostKeyFingerprint': hostKeyFingerprint,
      };

  factory SshConnection.fromJson(Map<String, dynamic> json) => SshConnection(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        username: json['username'] as String,
        authMethod: SshAuthMethod.values.firstWhere(
          (m) => m.name == json['authMethod'],
          orElse: () => SshAuthMethod.password,
        ),
        jumpHostId: json['jumpHostId'] as String?,
        hostKeyType: json['hostKeyType'] as String?,
        hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
      );
}

class SshCredentials {
  final String? password;
  final String? privateKey;
  final String? privateKeyPassphrase;

  const SshCredentials({
    this.password,
    this.privateKey,
    this.privateKeyPassphrase,
  });

  Map<String, dynamic> toJson() => {
        if (password != null) 'password': password,
        if (privateKey != null) 'privateKey': privateKey,
        if (privateKeyPassphrase != null)
          'privateKeyPassphrase': privateKeyPassphrase,
      };

  factory SshCredentials.fromJson(Map<String, dynamic> json) => SshCredentials(
        password: json['password'] as String?,
        privateKey: json['privateKey'] as String?,
        privateKeyPassphrase: json['privateKeyPassphrase'] as String?,
      );

  // Defensive: stringifying these accidentally (crash report, assertion
  // message, dev-tools state inspector) must never leak the credential.
  @override
  String toString() => 'SshCredentials('
      '${password != null ? "password=<redacted> " : ""}'
      '${privateKey != null ? "privateKey=<redacted> " : ""}'
      '${privateKeyPassphrase != null ? "privateKeyPassphrase=<redacted>" : ""}'
      ')';
}
