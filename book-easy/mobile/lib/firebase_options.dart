import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// TEMPLATE — replace by running `flutterfire configure` in this directory,
/// which regenerates this file with the real values from your Firebase
/// project. The placeholders below only exist so the repo compiles as-is.
///
/// NEVER commit a firebase_options.dart that points at a production project
/// you do not own; for this portfolio sample any throwaway project works.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for this platform. '
          'Run `flutterfire configure` to generate them.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'book-easy-sample',
    authDomain: 'book-easy-sample.firebaseapp.com',
    storageBucket: 'book-easy-sample.appspot.com',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'book-easy-sample',
    storageBucket: 'book-easy-sample.appspot.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'book-easy-sample',
    storageBucket: 'book-easy-sample.appspot.com',
    iosBundleId: 'com.example.bookEasy',
  );
}
