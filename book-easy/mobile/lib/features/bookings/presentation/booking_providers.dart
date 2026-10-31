import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failures.dart';
import '../../../core/services/fcm_service.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../payments/data/payment_sheet_service.dart';
import '../../payments/data/payments_api_client.dart';
import '../../payments/presentation/payment_providers.dart';
import '../../services/domain/service_item.dart';
import '../../services/presentation/services_providers.dart';
import '../data/bookings_repository.dart';
import '../domain/availability_service.dart';
import '../domain/booking.dart';

// ---- Repositories & services ----------------------------------------------

final bookingsRepositoryProvider = Provider<BookingsRepository>((ref) {
  return FirestoreBookingsRepository(ref.watch(firestoreProvider));
});

final availabilityServiceProvider = Provider<AvailabilityService>((ref) {
  return const AvailabilityService();
});

final fcmServiceProvider = Provider<FcmService>((ref) {
  return FirebaseFcmService(ref.watch(firestoreProvider));
});

// ---- Booking streams --------------------------------------------------------

/// Bookings of the signed-in user; empty while signed out.
final userBookingsProvider = StreamProvider<List<Booking>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value(const []);
  return ref.watch(bookingsRepositoryProvider).watchUserBookings(user.uid);
});

/// All bookings — admin screen only.
final allBookingsProvider = StreamProvider<List<Booking>>((ref) {
  return ref.watch(bookingsRepositoryProvider).watchAllBookings();
});

/// Active bookings starting on [day] (must be normalized to midnight).
final bookingsForDayProvider =
    StreamProvider.family<List<Booking>, DateTime>((ref, day) {
  final normalized = DateTime(day.year, day.month, day.day);
  return ref.watch(bookingsRepositoryProvider).watchBookingsForDay(normalized);
});

/// Query key for [availableSlotsProvider].
typedef SlotQuery = ({String serviceId, DateTime day});

/// Free slot start times for a service on a given day. Re-emits whenever a
/// booking for that day changes, so the grid stays fresh in real time.
final availableSlotsProvider =
    StreamProvider.family<List<DateTime>, SlotQuery>((ref, query) async* {
  final service = await ref.watch(serviceProvider(query.serviceId).future);
  final availability = ref.watch(availabilityServiceProvider);
  final normalizedDay =
      DateTime(query.day.year, query.day.month, query.day.day);

  // Watch the repository stream directly so slots recompute in real time
  // whenever a booking for the day changes.
  final dayBookingsStream =
      ref.watch(bookingsRepositoryProvider).watchBookingsForDay(normalizedDay);

  await for (final dayBookings in dayBookingsStream) {
    final busyPeriods = dayBookings
        .where((b) => b.serviceId == query.serviceId)
        .map((b) => (b.startsAt, b.endsAt))
        .toList(growable: false);

    yield availability.availableSlots(
      day: normalizedDay,
      durationMinutes: service.durationMinutes,
      busyPeriods: busyPeriods,
    );
  }
});

// ---- Checkout ----------------------------------------------------------------

sealed class CheckoutResult {
  const CheckoutResult();
}

/// Booking created and paid.
class CheckoutSuccess extends CheckoutResult {
  const CheckoutSuccess(this.booking);
  final Booking booking;
}

/// The user dismissed the payment sheet. The booking stays `pending` so
/// payment can be retried from booking details.
class CheckoutCancelled extends CheckoutResult {
  const CheckoutCancelled(this.pendingBooking);
  final Booking pendingBooking;
}

/// Something failed. [pendingBooking] is non-null when the booking was
/// created but payment did not complete (retry possible).
class CheckoutFailure extends CheckoutResult {
  const CheckoutFailure(this.failure, {this.pendingBooking});
  final Failure failure;
  final Booking? pendingBooking;
}

/// Orchestrates: create booking -> create PaymentIntent -> present Stripe
/// sheet -> mark paid -> subscribe to FCM reminders.
class BookingController {
  BookingController({
    required BookingsRepository bookings,
    required PaymentsApiClient paymentsApi,
    required PaymentSheetService paymentSheet,
    required FcmService fcm,
  })  : _bookings = bookings,
        _paymentsApi = paymentsApi,
        _paymentSheet = paymentSheet,
        _fcm = fcm;

  final BookingsRepository _bookings;
  final PaymentsApiClient _paymentsApi;
  final PaymentSheetService _paymentSheet;
  final FcmService _fcm;

  Future<CheckoutResult> checkout({
    required AppUser user,
    required ServiceItem service,
    required DateTime slot,
  }) async {
    final Booking booking;
    try {
      booking = await _bookings.createBooking(
        userId: user.uid,
        customerName: user.displayName,
        serviceId: service.id,
        serviceName: service.name,
        startsAt: slot,
        durationMinutes: service.durationMinutes,
        amountCents: service.priceCents,
        currency: service.currency,
      );
    } on Failure catch (failure) {
      return CheckoutFailure(failure);
    }
    return payForBooking(booking, user: user);
  }

  /// Runs the payment for an existing pending booking (also used to retry
  /// payment from the booking details screen).
  Future<CheckoutResult> payForBooking(Booking booking,
      {required AppUser user}) async {
    final String clientSecret;
    try {
      clientSecret = await _paymentsApi.createPaymentIntent(
        amountCents: booking.amountCents,
        currency: booking.currency,
        bookingId: booking.id,
        customerId: user.uid,
      );
    } on Failure catch (failure) {
      return CheckoutFailure(failure, pendingBooking: booking);
    }

    final outcome = await _paymentSheet.pay(clientSecret);
    switch (outcome) {
      case PaymentOutcome.cancelled:
        return CheckoutCancelled(booking);
      case PaymentOutcome.failure:
        return CheckoutFailure(
          const PaymentFailure(
              'Payment was declined. Please try again or use another card.'),
          pendingBooking: booking,
        );
      case PaymentOutcome.success:
        break;
    }

    try {
      await _bookings.markPaid(booking.id);
    } on Failure catch (failure) {
      // Money was captured but the booking update failed — surface it so the
      // user (and support) can reconcile; Stripe remains the source of truth.
      return CheckoutFailure(failure, pendingBooking: booking);
    }

    await _fcm.subscribeToBookingReminders(booking.id);

    final paid = booking.copyWith(
      status: BookingStatus.confirmed,
      paymentStatus: PaymentStatus.paid,
    );
    return CheckoutSuccess(paid);
  }
}

final bookingControllerProvider = Provider<BookingController>((ref) {
  return BookingController(
    bookings: ref.watch(bookingsRepositoryProvider),
    paymentsApi: ref.watch(paymentsApiClientProvider),
    paymentSheet: ref.watch(paymentSheetServiceProvider),
    fcm: ref.watch(fcmServiceProvider),
  );
});
