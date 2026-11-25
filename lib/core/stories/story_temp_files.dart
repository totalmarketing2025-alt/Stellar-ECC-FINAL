import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Removes decrypted media files left behind if Android killed Stellar while
/// a Story or chat attachment was open. Only viewer-owned files are touched.
Future<void> cleanupStoryTemporaryFiles({Directory? directory}) async {
  final temporary = directory ?? await getTemporaryDirectory();
  if (!await temporary.exists()) return;

  await for (final entity in temporary.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.isEmpty
        ? ''
        : entity.uri.pathSegments.last;
    if (!name.startsWith('stellar-story-') &&
        !name.startsWith('stellar_video_')) {
      continue;
    }
    try {
      await entity.delete();
    } on FileSystemException {
      // A concurrent OS cleanup is harmless; leave other files untouched.
    }
  }
}
