import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

/// Whether the picker should return a file path or a directory path.
enum RemotePickerMode { file, directory }

/// A simple SFTP file-browser. Push it as a route and `await` the result;
/// it resolves to the absolute remote path the user selected, or `null`
/// if the user cancelled.
///
/// * [RemotePickerMode.file] — tapping a file pops with that file's path.
///   Directories are still tappable (to navigate into them) but files
///   shown greyed-out in directory mode are still visible, only
///   non-selectable.
/// * [RemotePickerMode.directory] — a "SELECT" action appears in the
///   AppBar; tapping it returns the current directory path.
class RemoteFilePicker extends StatefulWidget {
  const RemoteFilePicker({
    super.key,
    required this.sftp,
    required this.mode,
    this.initialPath,
  });

  final SftpClient sftp;
  final RemotePickerMode mode;

  /// Start in this directory. If null, resolves to the SFTP session's
  /// home directory (via `sftp.absolute('.')`).
  final String? initialPath;

  static Future<String?> show(
    BuildContext context, {
    required SftpClient sftp,
    required RemotePickerMode mode,
    String? initialPath,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => RemoteFilePicker(
          sftp: sftp,
          mode: mode,
          initialPath: initialPath,
        ),
      ),
    );
  }

  @override
  State<RemoteFilePicker> createState() => _RemoteFilePickerState();
}

class _RemoteFilePickerState extends State<RemoteFilePicker> {
  String? _path;
  List<SftpName>? _entries;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Fire-and-forget: _navigate itself handles errors by surfacing them
    // in _error / setState, so we don't need to await it.
    unawaited(_navigate(widget.initialPath));
  }

  Future<void> _navigate(String? path) async {
    setState(() {
      _loading = true;
      _error = null;
      _entries = null;
    });
    try {
      // sftp.absolute('.') resolves to the SFTP home directory; it also
      // canonicalises whatever we pass in (resolving "..").
      final resolved = await widget.sftp.absolute(path ?? '.');
      final entries = await widget.sftp.listdir(resolved);
      entries.removeWhere((e) => _isUnsafeFilename(e.filename));
      _sortEntries(entries);
      if (!mounted) return;
      setState(() {
        _path = resolved;
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Filters out "." and ".." (we render our own parent entry) and anything
  /// a hostile SFTP server might return that would let a filename walk
  /// outside the current directory if we join it naively — embedded "/",
  /// NUL bytes, or empty strings.
  static bool _isUnsafeFilename(String name) {
    if (name.isEmpty || name == '.' || name == '..') return true;
    if (name.contains('/') || name.contains('\x00')) return true;
    return false;
  }

  static void _sortEntries(List<SftpName> list) {
    list.sort((a, b) {
      final aDir = a.attr.mode?.type == SftpFileType.directory;
      final bDir = b.attr.mode?.type == SftpFileType.directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    });
  }

  String _childPath(String name) {
    final path = _path ?? '/';
    return path.endsWith('/') ? '$path$name' : '$path/$name';
  }

  String _parentPath() {
    final path = _path ?? '/';
    if (path == '/') return '/';
    final trimmed =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final i = trimmed.lastIndexOf('/');
    if (i <= 0) return '/';
    return trimmed.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.mode == RemotePickerMode.directory
        ? 'Select folder'
        : 'Pick file';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title),
        actions: [
          if (widget.mode == RemotePickerMode.directory && _path != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop(_path),
              child: const Text('SELECT'),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(32),
          child: SizedBox(
            height: 32,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _path ?? '…',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ),
        ),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('$_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _navigate(_path),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final entries = _entries ?? const <SftpName>[];
    final isRoot = (_path ?? '/') == '/';
    final parentCount = isRoot ? 0 : 1;
    return ListView.builder(
      itemCount: entries.length + parentCount,
      itemBuilder: (context, index) {
        if (!isRoot && index == 0) {
          return ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('..'),
            subtitle: const Text('Parent directory'),
            onTap: () => _navigate(_parentPath()),
          );
        }
        final entry = entries[index - parentCount];
        final type = entry.attr.mode?.type;
        final isDir = type == SftpFileType.directory;
        final isLink = type == SftpFileType.symbolicLink;
        final fileSelectable = widget.mode == RemotePickerMode.file && !isDir;
        return ListTile(
          leading: Icon(
            isDir
                ? Icons.folder
                : isLink
                    ? Icons.link
                    : Icons.insert_drive_file,
            color: isDir ? theme.colorScheme.primary : null,
          ),
          title: Text(entry.filename),
          subtitle: _subtitle(entry),
          enabled: isDir || fileSelectable,
          onTap: () {
            if (isDir) {
              _navigate(_childPath(entry.filename));
            } else if (fileSelectable) {
              Navigator.of(context).pop(_childPath(entry.filename));
            }
          },
        );
      },
    );
  }

  Widget? _subtitle(SftpName entry) {
    final parts = <String>[];
    final size = entry.attr.size;
    if (size != null && entry.attr.mode?.type != SftpFileType.directory) {
      parts.add(_formatSize(size));
    }
    final mtime = entry.attr.modifyTime;
    if (mtime != null) {
      parts.add(_formatMtime(DateTime.fromMillisecondsSinceEpoch(mtime * 1000)));
    }
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '));
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    var v = bytes / 1024;
    for (final unit in const ['KiB', 'MiB', 'GiB', 'TiB']) {
      if (v < 1024) return '${v.toStringAsFixed(1)} $unit';
      v /= 1024;
    }
    return '${v.toStringAsFixed(1)} PiB';
  }

  static String _formatMtime(DateTime d) {
    final now = DateTime.now();
    final yearPrefix = d.year == now.year ? '' : '${d.year}-';
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '$yearPrefix$mm-$dd $hh:$mi';
  }
}
