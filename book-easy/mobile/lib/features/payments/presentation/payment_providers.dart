import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/payment_sheet_service.dart';
import '../data/payments_api_client.dart';

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final paymentsApiClientProvider = Provider<PaymentsApiClient>((ref) {
  return PaymentsApiClient(ref.watch(httpClientProvider));
});

final paymentSheetServiceProvider = Provider<PaymentSheetService>((ref) {
  return StripePaymentSheetService();
});
