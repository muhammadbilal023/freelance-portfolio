import 'package:book_easy/features/bookings/domain/booking.dart';
import 'package:flutter_test/flutter_test.dart';

Booking buildBooking({
  required DateTime startsAt,
  BookingStatus status = BookingStatus.confirmed,
}) {
  return Booking(
    id: 'b1',
    userId: 'u1',
    serviceId: 's1',
    serviceName: 'Haircut',
    startsAt: startsAt,
    durationMinutes: 30,
    amountCents: 4500,
    currency: 'usd',
    status: status,
    paymentStatus: PaymentStatus.paid,
  );
}

void main() {
  group('Booking.endsAt', () {
    test('is start plus duration', () {
      final booking = buildBooking(startsAt: DateTime(2026, 1, 5, 10));
      expect(booking.endsAt, DateTime(2026, 1, 5, 10, 30));
    });
  });

  group('Booking.canCancel (24h policy)', () {
    test('pending bookings can always be cancelled', () {
      final booking = buildBooking(
        startsAt: DateTime.now().add(const Duration(hours: 2)),
        status: BookingStatus.pending,
      );
      expect(booking.canCancel, isTrue);
    });

    test('confirmed bookings more than 24h away can be cancelled', () {
      final booking =
          buildBooking(startsAt: DateTime.now().add(const Duration(hours: 25)));
      expect(booking.canCancel, isTrue);
    });

    test('confirmed bookings inside 24h cannot be cancelled', () {
      final booking =
          buildBooking(startsAt: DateTime.now().add(const Duration(hours: 23)));
      expect(booking.canCancel, isFalse);
      expect(booking.canReschedule, isFalse);
    });

    test('cancelled and completed bookings cannot be cancelled again', () {
      final cancelled = buildBooking(
        startsAt: DateTime.now().add(const Duration(days: 3)),
        status: BookingStatus.cancelled,
      );
      final completed = buildBooking(
        startsAt: DateTime.now().add(const Duration(days: 3)),
        status: BookingStatus.completed,
      );
      expect(cancelled.canCancel, isFalse);
      expect(completed.canCancel, isFalse);
    });
  });

  group('Firestore round-trip', () {
    test('fromFirestore(toFirestore()) preserves fields', () {
      final original = buildBooking(startsAt: DateTime(2026, 1, 5, 10));
      final restored = Booking.fromFirestore('b1', original.toFirestore());

      expect(restored.id, original.id);
      expect(restored.serviceName, original.serviceName);
      expect(restored.startsAt, original.startsAt);
      expect(restored.amountCents, original.amountCents);
      expect(restored.status, BookingStatus.confirmed);
      expect(restored.paymentStatus, PaymentStatus.paid);
    });

    test('unknown status strings fall back to safe defaults', () {
      final booking = Booking.fromFirestore('b1', {
        'status': 'weird',
        'paymentStatus': 'weird',
      });
      expect(booking.status, BookingStatus.pending);
      expect(booking.paymentStatus, PaymentStatus.unpaid);
    });
  });
}
