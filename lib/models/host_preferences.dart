class HostPreferences {
  const HostPreferences({
    this.preferredColumns,
  });

  /// Desired terminal width in columns. `null` = auto-size to viewport.
  final int? preferredColumns;

  HostPreferences copyWith({
    int? preferredColumns,
    bool clearPreferredColumns = false,
  }) {
    return HostPreferences(
      preferredColumns: clearPreferredColumns
          ? null
          : (preferredColumns ?? this.preferredColumns),
    );
  }

  Map<String, dynamic> toJson() => {
        if (preferredColumns != null) 'preferredColumns': preferredColumns,
      };

  factory HostPreferences.fromJson(Map<String, dynamic> json) =>
      HostPreferences(
        preferredColumns: json['preferredColumns'] as int?,
      );

  bool get isEmpty => preferredColumns == null;
}
