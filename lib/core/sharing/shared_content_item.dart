class SharedContentItem {
  const SharedContentItem({
    required this.name,
    required this.mimeType,
    this.path,
    this.text,
    this.error,
  });

  final String name;
  final String mimeType;
  final String? path;
  final String? text;
  final String? error;

  factory SharedContentItem.fromMap(Map<Object?, Object?> map) {
    return SharedContentItem(
      name: map['name']?.toString() ?? 'Shared item',
      mimeType: map['mimeType']?.toString() ?? 'application/octet-stream',
      path: map['path']?.toString().isNotEmpty == true
          ? map['path']!.toString()
          : null,
      text: map['text']?.toString(),
      error: map['error']?.toString().isNotEmpty == true
          ? map['error']!.toString()
          : null,
    );
  }
}
