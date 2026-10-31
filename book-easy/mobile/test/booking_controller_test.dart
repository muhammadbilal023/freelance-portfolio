import 'dart:convert';

import 'package:book_easy/core/errors/failures.dart';
import 'package:book_easy/core/services/fcm_service.dart';
import 'package:book_easy/features/auth/domain/app_user.dart';
import 'package:book_easy/features/bookings/data/bookings_repository.dart';
import 'package:book_easy/features/bookings/domain/booking.dart';
import 'package:book_easy/features/bookings/presentation/booking_providers.dart';
import 'package:book_easy/features/payments/data/payment_sheet_service.dart';
import 'package:book_easy/features/payments/data/payments_api_client.dart';
import 'package:book_easy/features/services/domain/service_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ---- Fakes ------------------------------------------------------------------

class FakeBookingsRepository implements BookingsRepository {
  final created = <Booking>[];
  final paidIds = <String>[];
  Failure? failCreateWith;
  Failure? failMarkPaidWith;

  @override
  Stream<List<Booking>> watchUserBookings(String userId) =>
      Stream.value(const []);

  @override
  Stream<List<Booking>> watchAllBookings() => Stream.value(const []);

  @override
  Stream<List<Booking>> watchBookingsForDay(DateTime day) =>
      Stream.value(const []);

  @override
  Future<Booking> createBooking({
    required String userId,
    required String customerName,
    required String serviceId,
    required String serviceName,
    required DateTime startsAt,
    required int durationMinutes,
    required int amountCents,
    required String currency,
  }) async {
    if (failCreateWith != null) throw failCreateWith!;
    final booking = Booking(
      id: 'booking-1',
      userId: userId,
      customerName: customerName,
      serviceId: serviceId,
      serviceName: serviceName,
      startsAt: startsAt,
      durationMinutes: durationMinutes,
      amountCents: amountCents,
      currency: currency,
      status: BookingStatus.pending,
      paymentStatus: PaymentStatus.unpaid,
    );
    created.add(booking);
    return booking;
  }

  @override
  Future<void> markPaid(String bookingId) async {
    if (failMarkPaidWith != null) throw failMarkPaidWith!;
    paidIds.add(bookingId);
  }

  @override
  Future<void> cancelBooking(String bookingId) async {}

  @override
  Future<void> rescheduleBooking(
      String bookingId, DateTime newStartsAt) async {}

  @override
  Future<void> updateStatus(String bookingId, BookingStatus status) async {}
}

class FakePaymentSheet implements PaymentSheetService {
  FakePaymentSheet(this.outcome);

  final PaymentOutcome outcome;
  int callCount = 0;

  @override
  Future<PaymentOutcome> pay(String clientSecret) async {
    callCount++;
    return outcome;
  }
}

class FakeFcmService implements FcmService {
  final subscribed = <String>[];

  @override
  Future<void> registerDeviceToken(String uid) async {}

  @override
  Future<void> subscribeToBookingReminders(String bookingId) async {
    subscribed.add(bookingId);
  }

  @override
  Future<void> unsubscribeFromBookingReminders(String bookingId) async {}
}

/// Builds a [PaymentsApiClient] backed by a scripted HTTP mock.
PaymentsApiClient buildApiClient({
  int status = 201,
  Map<String, dynamic> body = const {
    'paymentIntentId': 'pi_1',
    'clientSecret': 'pi_1_secret',
    'status': 'requires_payment_method',
  },
}) {
  final mock = MockClient(
    (request) async => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    ),
  );
  return PaymentsApiClient(mock);
}

// ---- Fixtures ----------------------------------------------------------------

const testUser = AppUser(
  uid: 'user-1',
  email: 'client@example.com',
  displayName: 'Test Client',
  role: UserRole.client,
);

const testService = ServiceItem(
  id: 'service-1',
  name: 'Haircut',
  description: 'A classic haircut.',
  category: 'Salon',
  durationMinutes: 30,
  priceCents: 4500,
);

BookingController buildController({
  required FakeBookingsRepository bookings,
  required PaymentSheetService sheet,
  required FcmService fcm,
  PaymentsApiClient? apiClient,
}) {
  return BookingController(
    bookings: bookings,
    paymentsApi: apiClient ?? buildApiClient(),
    paymentSheet: sheet,
    fcm: fcm,
  );
}

void main() {
  final slot = DateTime.now().add(const Duration(days: 1, hours: 2));

  group('BookingController.checkout', () {
    test('happy path: creates booking, pays, marks paid, subscribes reminders',
        () async {
      final bookings = FakeBookingsRepository();
      final fcm = FakeFcmService();
      final controller = buildController(
        bookings: bookings,
        sheet: FakePaymentSheet(PaymentOutcome.success),
        fcm: fcm,
      );

      final result = await controller.checkout(
          user: testUser, service: testService, slot: slot);

      expect(result, isA<CheckoutSuccess>());
      final success = result as CheckoutSuccess;
      expect(success.booking.status, BookingStatus.confirmed);
      expect(success.booking.paymentStatus, PaymentStatus.paid);
      expect(bookings.paidIds, ['booking-1']);
      expect(fcm.subscribed, ['booking-1']);
    });

    test('amount and currency sent to the backend match the service price',
        () async {
      Map<String, dynamic>? sentBody;
      final mock = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'clientSecret': 'pi_1_secret'}),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final controller = buildController(
        bookings: FakeBookingsRepository(),
        sheet: FakePaymentSheet(PaymentOutcome.success),
        fcm: FakeFcmService(),
        apiClient: PaymentsApiClient(mock),
      );
      await controller.checkout(
          user: testUser, service: testService, slot: slot);

      expect(sentBody, isNotNull);
      expect(sentBody!['amount'], 4500);
      expect(sentBody!['currency'], 'usd');
      expect(sentBody!['bookingId'], 'booking-1');
    });

    test('user-cancelled payment sheet leaves booking pending', () async {
      final bookings = FakeBookingsRepository();
      final fcm = FakeFcmService();
      final controller = buildController(
        bookings: bookings,
        sheet: FakePaymentSheet(PaymentOutcome.cancelled),
        fcm: fcm,
      );

      final result = await controller.checkout(
          user: testUser, service: testService, slot: slot);

      expect(result, isA<CheckoutCancelled>());
      expect(bookings.paidIds, isEmpty);
      expect(fcm.subscribed, isEmpty);
      expect(bookings.created.single.status, BookingStatus.pending);
    });

    test('declined payment surfaces a PaymentFailure with the pending booking',
        () async {
      final bookings = FakeBookingsRepository();
      final controller = buildController(
        bookings: bookings,
        sheet: FakePaymentSheet(PaymentOutcome.failure),
        fcm: FakeFcmService(),
      );

      final result = await controller.checkout(
          user: testUser, service: testService, slot: slot);

      expect(result, isA<CheckoutFailure>());
      final failure = result as CheckoutFailure;
      expect(failure.failure, isA<PaymentFailure>());
      expect(failure.pendingBooking?.id, 'booking-1');
      expect(bookings.paidIds, isEmpty);
    });

    test('backend error response is mapped to a failure with its message',
        () async {
      final controller = buildController(
        bookings: FakeBookingsRepository(),
        sheet: FakePaymentSheet(PaymentOutcome.success),
        fcm: FakeFcmService(),
        apiClient: buildApiClient(
          status: 400,
          body: {
            'error': {
              'code': 'validation_error',
              'message': 'amount must be positive'
            },
          },
        ),
      );

      final result = await controller.checkout(
          user: testUser, service: testService, slot: slot);

      expect(result, isA<CheckoutFailure>());
      final failure = result as CheckoutFailure;
      expect(failure.failure.message, contains('amount must be positive'));
      expect(failure.pendingBooking?.id, 'booking-1');
    });

    test('booking creation failure short-circuits before payment', () async {
      final bookings = FakeBookingsRepository()
        ..failCreateWith =
            const ValidationFailure('Choose a slot in the future.');
      final sheet = FakePaymentSheet(PaymentOutcome.success);
      final controller = buildController(
          bookings: bookings, sheet: sheet, fcm: FakeFcmService());

      final result = await controller.checkout(
          user: testUser, service: testService, slot: slot);

      expect(result, isA<CheckoutFailure>());
      expect((result as CheckoutFailure).pendingBooking, isNull);
      expect(sheet.callCount, 0);
    });

    test(
        'markPaid failure after successful payment is surfaced for reconciliation',
        () async {
      final bookings = FakeBookingsRepository()
        ..failMarkPaidWith =
            const UnexpectedFailure('The update failed. Please try again.');
      final controller = buildController(
        bookings: bookings,
        sheet: FakePaymentSheet(PaymentOutcome.success),
        fcm: FakeFcmService(),
      );

      final result = await controller.checkout(
          user: testUser, service: testService, slot: slot);

      expect(result, isA<CheckoutFailure>());
      expect((result as CheckoutFailure).pendingBooking?.id, 'booking-1');
    });
  });
}
