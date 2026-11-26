import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stellar_ecc/core/storage/database.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS opens the local database with SQLCipher', (tester) async {
    final database = await StellarDatabase.open();
    addTearDown(database.close);

    // StellarDatabase.open fails closed unless PRAGMA cipher_version is
    // present, so reaching this assertion verifies SQLCipher was loaded.
    expect(database.messageDao, isNotNull);
  });
}
