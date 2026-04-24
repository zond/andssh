class HostPreferences {
  const HostPreferences({
    this.preferredColumns,
    this.lastLocalDir,
    this.lastRemoteDir,
  });

  /// Desired terminal width in columns. `null` = auto-size to viewport.
  final int? preferredColumns;

  /// Last directory the user picked (or saved into) on the Android side.
  /// Fed back as `initialDirectory` to the file picker; safe to ignore
  /// if the platform doesn't honour it.
  final String? lastLocalDir;

  /// Last remote directory the user browsed for an upload destination or
  /// a download source. Used as the starting path for the in-app SFTP
  /// browser the next time the user opens it for this host.
  final String? lastRemoteDir;

  HostPreferences copyWith({
    int? preferredColumns,
    bool clearPreferredColumns = false,
    String? lastLocalDir,
    String? lastRemoteDir,
  }) {
    return HostPreferences(
      preferredColumns: clearPreferredColumns
          ? null
          : (preferredColumns ?? this.preferredColumns),
      lastLocalDir: lastLocalDir ?? this.lastLocalDir,
      lastRemoteDir: lastRemoteDir ?? this.lastRemoteDir,
    );
  }

  Map<String, dynamic> toJson() => {
        if (preferredColumns != null) 'preferredColumns': preferredColumns,
        if (lastLocalDir != null) 'lastLocalDir': lastLocalDir,
        if (lastRemoteDir != null) 'lastRemoteDir': lastRemoteDir,
      };

  factory HostPreferences.fromJson(Map<String, dynamic> json) =>
      HostPreferences(
        preferredColumns: json['preferredColumns'] as int?,
        lastLocalDir: json['lastLocalDir'] as String?,
        lastRemoteDir: json['lastRemoteDir'] as String?,
      );

  bool get isEmpty =>
      preferredColumns == null &&
      lastLocalDir == null &&
      lastRemoteDir == null;
}
