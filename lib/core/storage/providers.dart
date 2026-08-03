import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';

/// Overridden in main.dart with the real, already-opened database instance
/// so the async open() call happens exactly once, before runApp().
final databaseProvider = Provider<StellarDatabase>((ref) {
  throw UnimplementedError('databaseProvider must be overridden in main.dart');
});
