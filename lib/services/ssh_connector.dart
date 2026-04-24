import 'dart:async';
import 'dart:developer' as developer;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/ssh_connection.dart';
import 'connection_store.dart';
import 'secret_store.dart';

void _log(String msg) => developer.log(msg, name: 'andssh');

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
  ///
  /// Host-key verification:
  ///   * If a hop has no pinned key ([SshConnection.hostKeyFingerprint]
  ///     is null), the connect captures the server's fingerprint via
  ///     [onHostKeyObserved] and trusts it on first use.
  ///   * If a hop has a pinned key and the server's fingerprint matches,
  ///     the connect proceeds.
  ///   * If a hop has a pinned key and the fingerprint does NOT match,
  ///     this method throws [HostKeyMismatchError] so the UI can show the
  ///     old/new fingerprints and let the user ignore / update / abort.
  Future<SshClientBundle> connect({
    required SshConnection target,
    required SshCredentials targetCreds,
    void Function(String line)? onProgress,
    void Function(SshConnection hop, String type, String fingerprintHex)?
        onHostKeyObserved,
  }) async {
    void progress(String line) {
      _log(line);
      onProgress?.call(line);
    }

    final chain = _store.resolveJumpChain(target);
    // chain[0] = target, chain[last] = outermost jump host.
    final hops = chain.reversed.toList();
    if (hops.length > 1) {
      final chainStr = hops
          .map((h) => '${h.username}@${h.host}:${h.port}')
          .join(' → ');
      progress('Chain: $chainStr');
    }

    final clients = <SSHClient>[];
    progress('[1/${hops.length}] TCP connect to '
        '${hops.first.host}:${hops.first.port}…');
    SSHSocket socket =
        await SSHSocket.connect(hops.first.host, hops.first.port);
    // `socket` is the direct-connect TCP until the first hop
    // authenticates, after which each hop hands us a `forwardLocal`
    // channel we reassign into `socket`. Those channel sockets are
    // owned by their originating client and close when the client
    // closes; the outer TCP socket, however, is only reachable via
    // this local variable until the first SSHClient adopts it. Track
    // it separately so we can close it if we fail before handing it
    // off.
    SSHSocket? unadoptedSocket = socket;
    HostKeyMismatchError? mismatch;

    try {
      for (var i = 0; i < hops.length; i++) {
        final hop = hops[i];
        final step = i + 1;
        final isTarget = i == hops.length - 1;
        final role = isTarget ? 'target' : 'jump host';
        progress('[$step/${hops.length}] Authenticating to $role '
            '${hop.username}@${hop.host} (${hop.authMethod.name})…');
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
          onVerifyHostKey: (type, fingerprint) {
            final observedFp = _fingerprintHex(fingerprint);
            final pinnedType = hop.hostKeyType;
            final pinnedFp = hop.hostKeyFingerprint;
            if (pinnedFp == null) {
              // TOFU — accept and let the caller persist the observation.
              progress(
                  '    host key (new): $type ${_displayFp(observedFp)}');
              onHostKeyObserved?.call(hop, type, observedFp);
              return true;
            }
            if (pinnedType == type && pinnedFp == observedFp) {
              return true;
            }
            // Mismatch: stash the details + reject. dartssh2 will then
            // throw SSHHostkeyError out of `client.authenticated`, which
            // we catch below and convert into a HostKeyMismatchError.
            mismatch = HostKeyMismatchError(
              hop: hop,
              pinnedType: pinnedType,
              pinnedFingerprint: pinnedFp,
              observedType: type,
              observedFingerprint: observedFp,
            );
            progress('    ✗ host key mismatch on ${hop.host}');
            return false;
          },
          // Only forward dartssh2's protocol debug in debug builds; it can
          // include algorithm names, key-exchange state, and the like —
          // fingerprintable and occasionally sensitive in error paths.
          printDebug: kDebugMode ? (m) => _log('[${hop.name}] $m') : null,
        );
        // SSHClient now owns the socket; if anything later in this hop
        // throws, closing the client will close the socket too.
        unadoptedSocket = null;
        try {
          await client.authenticated;
        } catch (e, st) {
          progress('    ✗ auth failed: $e');
          _log('$st');
          // Client didn't fully authenticate, but it has already adopted
          // the socket — close it to tear down the TCP layer too.
          client.close();
          if (mismatch != null) throw mismatch!;
          rethrow;
        }
        progress('    ✓ authenticated');
        clients.add(client);

        if (!isTarget) {
          final next = hops[i + 1];
          progress('    → tunnelling to ${next.host}:${next.port}');
          try {
            socket = await client.forwardLocal(next.host, next.port);
          } catch (e, st) {
            progress('    ✗ tunnel failed: $e');
            _log('$st');
            rethrow;
          }
        }
      }

      return SshClientBundle(clients);
    } catch (_) {
      // Partial-chain failure — close any hops we authenticated before
      // the failure, newest-first (each tunnel channel is owned by the
      // client whose forwardLocal created it). Also close the unadopted
      // outer TCP socket if we never got far enough for it to be owned.
      for (final c in clients.reversed) {
        try {
          c.close();
        } catch (_) {}
      }
      final orphan = unadoptedSocket;
      if (orphan != null) {
        try {
          orphan.close();
        } catch (_) {}
      }
      rethrow;
    }
  }
}

/// Raised when a hop's server-reported host key doesn't match the one
/// pinned on the connection. The UI surfaces the pinned vs observed
/// fingerprints and lets the user re-pin (trust the new key) or abort.
class HostKeyMismatchError implements Exception {
  HostKeyMismatchError({
    required this.hop,
    required this.pinnedType,
    required this.pinnedFingerprint,
    required this.observedType,
    required this.observedFingerprint,
  });

  /// The hop in the chain where the mismatch was detected.
  final SshConnection hop;

  /// The previously-pinned host key type (e.g. `ssh-ed25519`).
  final String? pinnedType;

  /// The previously-pinned host key fingerprint as lowercase hex.
  final String pinnedFingerprint;

  /// The type dartssh2 reported on this connect.
  final String observedType;

  /// The MD5 fingerprint hex dartssh2 reported on this connect.
  final String observedFingerprint;

  @override
  String toString() =>
      'HostKeyMismatchError(${hop.host}: expected '
      '$pinnedType ${_displayFp(pinnedFingerprint)}, '
      'got $observedType ${_displayFp(observedFingerprint)})';
}

String _fingerprintHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Pretty-print a fingerprint hex string as colon-separated pairs
/// (`ab:cd:ef:…`) — matches how OpenSSH / ssh-keygen format MD5
/// fingerprints for human display.
String _displayFp(String hex) {
  final pairs = <String>[];
  for (var i = 0; i < hex.length; i += 2) {
    pairs.add(hex.substring(i, i + 2));
  }
  return pairs.join(':');
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
