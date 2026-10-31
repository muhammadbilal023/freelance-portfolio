import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import 'app.dart';
import 'core/env/app_config.dart';
import 'core/utils/logger.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initLogging();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // The publishable key is safe to embed in clients; the secret key never
  // leaves the payments backend.
  Stripe.publishableKey = AppConfig.stripePublishableKey;

  runApp(const ProviderScope(child: BookEasyApp()));
}
