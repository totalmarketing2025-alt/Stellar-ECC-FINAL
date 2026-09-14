// File generated normally by the `flutterfire configure` CLI against your
// own Firebase project — this is standard practice for every Flutter+Firebase
// app (the values are project-specific API identifiers, not secrets you'd
// hand-author). Structure below is correct and complete; run:
//
//   dart pub global activate flutterfire_cli
//   flutterfire configure --project=<your-firebase-project-id>
//
// and let it overwrite this file with your real project's values before
// building. Do not commit real API keys to a public repo without confirming
// your Firebase project's API key restrictions are configured appropriately.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Stellar ECC does not ship a web target.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyA5oVVSPnVwTRlLW4F1mkmR0gKoXtXRnlY',
    appId: '1:242256147600:android:24b90075fab175f6e69415',
    messagingSenderId: '242256147600',
    projectId: 'stellar-adc4b',
    storageBucket: 'stellar-adc4b.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_WITH_YOUR_IOS_API_KEY',
    appId: 'REPLACE_WITH_YOUR_IOS_APP_ID',
    messagingSenderId: '242256147600',
    projectId: 'stellar-adc4b',
    storageBucket: 'stellar-adc4b.firebasestorage.app',
    iosBundleId: 'ecc.stellar.app',
  );
}
