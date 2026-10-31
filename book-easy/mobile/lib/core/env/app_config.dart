/// Compile-time configuration injected with `--dart-define`.
///
/// Nothing here is a secret: the Stripe *publishable* key is designed to be
/// shipped inside client apps. Secret keys live only in the backend `.env`.
class AppConfig {
  const AppConfig._();

  /// Base URL of the BookEasy payments backend.
  static const String paymentsApiUrl = String.fromEnvironment(
    'PAYMENTS_API_URL',
    defaultValue: 'http://10.0.2.2:8080', // Android emulator -> host machine
  );

  /// Stripe publishable key (pk_test_...) for the mobile client.
  static const String stripePublishableKey = String.fromEnvironment(
    'STRIPE_PUBLISHABLE_KEY',
    defaultValue: '',
  );

  /// Display name shown on the Stripe payment sheet.
  static const String merchantDisplayName = 'BookEasy';
}
