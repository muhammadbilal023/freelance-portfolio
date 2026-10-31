import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:logging/logging.dart';

import '../../../core/env/app_config.dart';

/// Result of presenting the Stripe payment sheet.
enum PaymentOutcome {
  success,

  /// The user dismissed the sheet — not an error worth a red banner.
  cancelled,
  failure,
}

/// Thin wrapper around flutter_stripe so the rest of the app never imports
/// the SDK directly (and can be tested against a fake).
abstract interface class PaymentSheetService {
  Future<PaymentOutcome> pay(String clientSecret);
}

class StripePaymentSheetService implements PaymentSheetService {
  final Logger _log = Logger('StripePaymentSheet');

  @override
  Future<PaymentOutcome> pay(String clientSecret) async {
    try {
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: AppConfig.merchantDisplayName,
          style: ThemeMode.system,
        ),
      );
      await Stripe.instance.presentPaymentSheet();
      _log.info('Payment sheet completed successfully');
      return PaymentOutcome.success;
    } on StripeException catch (e) {
      if (e.error.code == FailureCode.Canceled) {
        return PaymentOutcome.cancelled;
      }
      _log.warning(
          'Payment failed: ${e.error.localizedMessage ?? e.error.code}');
      return PaymentOutcome.failure;
    } catch (error) {
      _log.severe('Unexpected payment sheet error', error);
      return PaymentOutcome.failure;
    }
  }
}
