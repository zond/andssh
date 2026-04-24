import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// Progress + cancellation signal for a single upload or download. The
/// transfer functions update [bytesDone] / [bytesTotal] as the stream
/// progresses and honour [cancelled] by stopping at the next chunk
/// boundary.
class TransferController extends ChangeNotifier {
  /// Display name for the dialog — usually the basename of the file.
  String filename;

  int bytesDone = 0;

  /// Total size in bytes, or null if not known yet.
  int? bytesTotal;

  bool _cancelled = false;
  bool get cancelled => _cancelled;

  TransferController({this.filename = ''});

  /// Ask the in-flight transfer to stop at the next chunk boundary.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    notifyListeners();
  }

  void _setSize(int size) {
    bytesTotal = size;
    notifyListeners();
  }

  void _advance(int bytes) {
    bytesDone = bytes;
    notifyListeners();
  }

  double? get progress {
    final total = bytesTotal;
    if (total == null || total == 0) return null;
    return (bytesDone / total).clamp(0.0, 1.0);
  }
}

/// Thrown when a transfer is cancelled via [TransferController.cancel].
class TransferCancelled implements Exception {
  const TransferCancelled();
  @override
  String toString() => 'TransferCancelled';
}

/// Streams [local] to [remotePath] on the SFTP server. Creates the remote
/// file (truncating if it already exists). The local file is read in
/// chunks so memory usage stays bounded regardless of size.
Future<void> uploadFile({
  required File local,
  required SftpClient sftp,
  required String remotePath,
  required TransferController controller,
}) async {
  final size = await local.length();
  controller._setSize(size);

  final remote = await sftp.open(
    remotePath,
    mode: SftpFileOpenMode.write |
        SftpFileOpenMode.create |
        SftpFileOpenMode.truncate,
  );
  try {
    var offset = 0;
    await for (final chunk in local.openRead()) {
      if (controller.cancelled) throw const TransferCancelled();
      final bytes =
          chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      await remote.writeBytes(bytes, offset: offset);
      offset += bytes.length;
      controller._advance(offset);
    }
  } finally {
    await remote.close();
  }
}

/// Streams [remotePath] on the SFTP server into [local], overwriting
/// anything already at that local path. Uses [SftpFile.read], which
/// chunks the transfer.
Future<void> downloadFile({
  required SftpClient sftp,
  required String remotePath,
  required File local,
  required TransferController controller,
}) async {
  final remote = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
  try {
    final stat = await remote.stat();
    final size = stat.size;
    if (size != null) controller._setSize(size);

    final sink = local.openWrite();
    var bytesWritten = 0;
    try {
      await for (final chunk in remote.read()) {
        if (controller.cancelled) throw const TransferCancelled();
        sink.add(chunk);
        bytesWritten += chunk.length;
        controller._advance(bytesWritten);
      }
    } finally {
      await sink.close();
    }
  } finally {
    await remote.close();
  }
}
