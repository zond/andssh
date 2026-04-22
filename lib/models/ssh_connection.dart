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

  const SshConnection({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.jumpHostId,
  });

  SshConnection copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    SshAuthMethod? authMethod,
    String? jumpHostId,
    bool clearJumpHost = false,
  }) {
    return SshConnection(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      jumpHostId: clearJumpHost ? null : (jumpHostId ?? this.jumpHostId),
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
}
