import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// ---------------------------------------------------------------
/// HOW TO GET THESE VALUES:
///
/// 1. Go to https://console.firebase.google.com
/// 2. Create a new project (e.g. "strata-app")
/// 3. Click the Web icon (</>) to add a web app
/// 4. Copy the config values from the snippet Firebase shows you
/// 5. Go to Authentication > Sign-in method > Phone > Enable
/// 6. Replace the placeholder strings below with your real values
/// ---------------------------------------------------------------
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  // ----- PASTE YOUR WEB CONFIG VALUES HERE -----
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: "AIzaSyA-Nh5CQKNx01a_kK9HJ2V0D6N5gBTwJoM",
    appId: "1:250214999515:web:85822d5eb66769142473fe",
    messagingSenderId: "250214999515",
    projectId: "strata-app-cf9d4",
    authDomain: "strata-app-cf9d4.firebaseapp.com",
    storageBucket: "strata-app-cf9d4.firebasestorage.app",
  );

  // ----- PASTE YOUR ANDROID CONFIG VALUES HERE (optional) -----
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: "AIzaSyA-Nh5CQKNx01a_kK9HJ2V0D6N5gBTwJoM",
    appId: "1:250214999515:web:85822d5eb66769142473fe",
    messagingSenderId: "250214999515",
    projectId: "strata-app-cf9d4",
    storageBucket: "strata-app-cf9d4.firebasestorage.app",
  );

  // ----- PASTE YOUR iOS CONFIG VALUES HERE (optional) -----
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: "AIzaSyA-Nh5CQKNx01a_kK9HJ2V0D6N5gBTwJoM",
    appId: "1:250214999515:web:85822d5eb66769142473fe",
    messagingSenderId: "250214999515",
    projectId: "strata-app-cf9d4",
    storageBucket: "strata-app-cf9d4.firebasestorage.app",
    iosBundleId: 'com.example.strata',
  );
}
