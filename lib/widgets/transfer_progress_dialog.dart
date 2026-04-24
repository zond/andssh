import 'package:flutter/material.dart';

import '../services/file_transfer.dart';

/// Modal dialog that watches a [TransferController] and shows filename,
/// bytes / percent, and a Cancel button. The dialog does not auto-dismiss;
/// the caller is responsible for popping it when the transfer future
/// resolves (so the caller can surface errors afterwards).
class TransferProgressDialog extends StatelessWidget {
  const TransferProgressDialog({
    super.key,
    required this.controller,
    required this.title,
  });

  final TransferController controller;

  /// e.g. "Uploading" or "Downloading" — used as the dialog title.
  final String title;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Block the hardware back button — the user has to press Cancel
      // explicitly so there's no ambiguity about whether the transfer
      // was aborted.
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final total = controller.bytesTotal;
            final done = controller.bytesDone;
            final progress = controller.progress;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  controller.filename.isEmpty ? '…' : controller.filename,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 8),
                Text(
                  total == null
                      ? _formatBytes(done)
                      : '${_formatBytes(done)} / ${_formatBytes(total)}'
                          '  ·  ${((progress ?? 0) * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (controller.cancelled) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Cancelling…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                ],
              ],
            );
          },
        ),
        actions: [
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) => TextButton(
              onPressed: controller.cancelled ? null : controller.cancel,
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    var v = bytes / 1024;
    for (final unit in const ['KiB', 'MiB', 'GiB', 'TiB']) {
      if (v < 1024) return '${v.toStringAsFixed(1)} $unit';
      v /= 1024;
    }
    return '${v.toStringAsFixed(1)} PiB';
  }
}
