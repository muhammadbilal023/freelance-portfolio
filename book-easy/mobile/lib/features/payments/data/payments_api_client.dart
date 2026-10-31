import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../../core/env/app_config.dart';
import '../../../core/errors/failures.dart';

/// HTTP client for the BookEasy payments backend.
///
/// Only the *publishable* flow touches the client: the backend creates the
/// PaymentIntent with the secret key and returns a single-use client secret.
class PaymentsApiClient {
  PaymentsApiClient(this._client);

  final http.Client _client;
  final Logger _log = Logger('PaymentsApiClient');

  static const Duration _timeout = Duration(seconds: 15);

  /// Returns the PaymentIntent client secret.
  Future<String> createPaymentIntent({
    required int amountCents,
    required String currency,
    String? bookingId,
    String? customerId,
  }) async {
    final uri =
        Uri.parse('${AppConfig.paymentsApiUrl}/api/payments/payment-intent');

    try {
      final response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'amount': amountCents,
              'currency': currency,
              if (bookingId != null) 'bookingId': bookingId,
              if (customerId != null) 'customerId': customerId,
            }),
          )
          .timeout(_timeout);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 201) {
        final clientSecret = body['clientSecret'] as String?;
        if (clientSecret == null || clientSecret.isEmpty) {
          throw const PaymentFailure(
              'The payment server returned an invalid response.');
        }
        return clientSecret;
      }

      final error = body['error'] as Map<String, dynamic>?;
      final message = error?['message'] as String? ?? 'Payment request failed.';
      _log.warning('Backend error ${response.statusCode}: $message');
      throw PaymentFailure(message);
    } on TimeoutException {
      throw const NetworkFailure(
          'The payment server took too long. Check your connection.');
    } on SocketException {
      throw const NetworkFailure();
    } on HttpException {
      throw const NetworkFailure();
    } on FormatException {
      throw const PaymentFailure(
          'The payment server returned an invalid response.');
    }
  }
}
