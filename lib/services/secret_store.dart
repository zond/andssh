import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../models/ssh_connection.dart';

/// Biometric-gated storage for SSH credentials.
///
/// Credentials are stored in the Android Keystore via flutter_secure_storage
/// (EncryptedSharedPreferences), and every read is gated behind a
/// fingerprint / device-credential prompt from local_auth.
class SecretStore {
  // flutter_secure_storage v10 migrated off Jetpack Security (now deprecated
  // upstream) to its own Keystore-wrapped AEAD; `encryptedSharedPreferences`
  // is accepted but ignored. `resetOnError` guards against a corrupt store
  // bricking every read.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true),
  );

  final LocalAuthentication _auth = LocalAuthentication();

  String _keyFor(String connectionId) => 'ssh_secret_$connectionId';

  Future<bool> _authenticate(String reason) async {
    return _auth.authenticate(
      localizedReason: reason,
      biometricOnly: false,
      persistAcrossBackgrounding: true,
    );
  }

  Future<void> save(String connectionId, SshCredentials creds) async {
    final ok = await _authenticate('Unlock to save SSH credentials');
    if (!ok) {
      throw const BiometricAuthFailure();
    }
    await _storage.write(
      key: _keyFor(connectionId),
      value: jsonEncode(creds.toJson()),
    );
  }

  Future<SshCredentials?> load(String connectionId) async {
    final raw = await _storage.read(key: _keyFor(connectionId));
    if (raw == null) return null;
    final ok = await _authenticate('Unlock SSH credentials');
    if (!ok) {
      throw const BiometricAuthFailure();
    }
    return _decodeOrDiscard(connectionId, raw);
  }

  /// Load without biometric prompt. Only use this for background reads like
  /// chaining jump host credentials after the user has already authenticated
  /// for the outermost connection.
  Future<SshCredentials?> loadUnlocked(String connectionId) async {
    final raw = await _storage.read(key: _keyFor(connectionId));
    if (raw == null) return null;
    return _decodeOrDiscard(connectionId, raw);
  }

  /// Parses [raw] or, on failure, deletes the corrupted entry and returns
  /// null so the caller can surface "missing credentials" and let the user
  /// re-enter them rather than wedge on a JSON/shape error forever.
  Future<SshCredentials?> _decodeOrDiscard(
    String connectionId,
    String raw,
  ) async {
    try {
      return SshCredentials.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await _storage.delete(key: _keyFor(connectionId));
      return null;
    }
  }

  Future<void> delete(String connectionId) async {
    await _storage.delete(key: _keyFor(connectionId));
  }
}

class BiometricAuthFailure implements Exception {
  const BiometricAuthFailure();
  @override
  String toString() => 'Biometric authentication failed or was cancelled';
}
