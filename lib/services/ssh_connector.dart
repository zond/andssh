import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import '../models/ssh_connection.dart';
import 'connection_store.dart';
import 'secret_store.dart';

/// Opens an [SSHClient] for [target], following its jump host chain.
///
/// The outermost hop (the last element of the resolved chain) is dialled
/// with a regular TCP socket; each subsequent hop is dialled through the
/// previous hop's [SSHClient.forwardLocal] channel — the same mechanism
/// OpenSSH's `ProxyJump` uses.
class SshConnector {
  SshConnector(this._store, this._secrets);

  final ConnectionStore _store;
  final SecretStore _secrets;

  /// Caller provides credentials for [target] (already unlocked via
  /// biometrics). Credentials for jump hosts along the chain are loaded
  /// unlocked, riding on the same biometric unlock.
  Future<SshClientBundle> connect({
    required SshConnection target,
    required SshCredentials targetCreds,
  }) async {
    final chain = _store.resolveJumpChain(target);
    // chain[0] = target, chain[last] = outermost jump host.
    final hops = chain.reversed.toList();

    final clients = <SSHClient>[];
    SSHSocket socket =
        await SSHSocket.connect(hops.first.host, hops.first.port);

    for (var i = 0; i < hops.length; i++) {
      final hop = hops[i];
      final isTarget = i == hops.length - 1;
      final creds = isTarget
          ? targetCreds
          : (await _secrets.loadUnlocked(hop.id)) ??
              (throw StateError(
                  'Missing stored credentials for jump host "${hop.name}"'));

      final client = SSHClient(
        socket,
        username: hop.username,
        identities: hop.authMethod == SshAuthMethod.privateKey &&
                creds.privateKey != null
            ? SSHKeyPair.fromPem(
                creds.privateKey!,
                creds.privateKeyPassphrase,
              )
            : null,
        onPasswordRequest: hop.authMethod == SshAuthMethod.password
            ? () => creds.password ?? ''
            : null,
      );
      await client.authenticated;
      clients.add(client);

      if (!isTarget) {
        final next = hops[i + 1];
        socket = await client.forwardLocal(next.host, next.port);
      }
    }

    return SshClientBundle(clients);
  }
}

/// Holds the chain of [SSHClient]s opened for one session. The last client
/// is the one to open a shell on; the rest are jump hosts kept alive to
/// keep the forwarded channels open.
class SshClientBundle {
  SshClientBundle(this.clients);
  final List<SSHClient> clients;

  SSHClient get target => clients.last;

  Future<void> close() async {
    for (final c in clients.reversed) {
      c.close();
      await c.done;
    }
  }
}
