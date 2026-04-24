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
/// file (truncating if it already exists).
///
/// Uses [SftpFile.write], which starts an [SftpFileWriter] with built-in
/// sliding-window flow control (it pauses the local stream when the
/// remote hasn't acked enough). The previous implementation drove each
/// 64-KiB chunk through `writeBytes` serially, which was simpler but
/// also unbounded in in-flight requests and didn't back-pressure the
/// local file stream at all.
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
    // File.openRead() yields List<int>; the writer wants Uint8List.
    final stream = local.openRead().map(
          (chunk) =>
              chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
        );
    final writer = remote.write(
      stream,
      onProgress: controller._advance,
    );
    // Forward cancellation: aborting the writer cancels the stream
    // subscription, completes `writer.done`, and we treat that as a
    // TransferCancelled.
    void onCancel() {
      if (controller.cancelled) unawaited(writer.abort());
    }
    controller.addListener(onCancel);
    try {
      await writer.done;
    } finally {
      controller.removeListener(onCancel);
    }
    if (controller.cancelled) throw const TransferCancelled();
  } finally {
    // Swallow close errors — the original transfer exception (if any)
    // is what the user needs to see; a follow-up close failure on a
    // half-dead channel would otherwise mask it.
    try {
      await remote.close();
    } catch (_) {}
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
      // Don't let a close-time error (e.g. disk-full flush) mask the
      // actual cause of failure if one is already propagating out.
      try {
        await sink.close();
      } catch (_) {}
    }
  } finally {
    try {
      await remote.close();
    } catch (_) {}
  }
}
