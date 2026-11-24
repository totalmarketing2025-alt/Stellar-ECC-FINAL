import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Removes decrypted video files left behind if Android killed Stellar while
/// a Story was open. Only files owned by the Stories viewer are touched.
Future<void> cleanupStoryTemporaryFiles({Directory? directory}) async {
  final temporary = directory ?? await getTemporaryDirectory();
  if (!await temporary.exists()) return;

  await for (final entity in temporary.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.isEmpty
        ? ''
        : entity.uri.pathSegments.last;
    if (!name.startsWith('stellar-story-')) continue;
    try {
      await entity.delete();
    } on FileSystemException {
      // A concurrent OS cleanup is harmless; leave other files untouched.
    }
  }
}
