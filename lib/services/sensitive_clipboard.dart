import 'package:flutter/services.dart';

/// Thin wrapper around Android's `ClipboardManager` that marks the primary
/// clip as sensitive (`ClipDescription.EXTRA_IS_SENSITIVE`, API 33+). On
/// supporting versions Android then suppresses the paste-toast preview
/// and elides the content in system UI. Pre-API-33 falls back to the
/// normal Flutter clipboard call.
class SensitiveClipboard {
  static const MethodChannel _ch = MethodChannel('andssh/clipboard');

  /// Copies [text] to the primary clipboard with the sensitive flag set.
  static Future<void> setData(String text) async {
    try {
      await _ch.invokeMethod<void>('setSensitiveText', {'text': text});
    } on MissingPluginException {
      // Platform channel not wired (e.g. on a host platform we don't
      // ship to); fall back so the copy at least works.
      await Clipboard.setData(ClipboardData(text: text));
    }
  }
}
