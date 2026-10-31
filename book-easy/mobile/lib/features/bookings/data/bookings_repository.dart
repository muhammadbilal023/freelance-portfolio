import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:logging/logging.dart';

import '../../../core/errors/failures.dart';
import '../domain/booking.dart';

abstract interface class BookingsRepository {
  /// Bookings of one user, newest first.
  Stream<List<Booking>> watchUserBookings(String userId);

  /// All bookings — admin screen.
  Stream<List<Booking>> watchAllBookings();

  /// Active (pending/confirmed) bookings that start on [day] — used to
  /// compute slot availability.
  Stream<List<Booking>> watchBookingsForDay(DateTime day);

  /// Creates a booking in `pending` state; payment confirmation follows.
  Future<Booking> createBooking({
    required String userId,
    required String customerName,
    required String serviceId,
    required String serviceName,
    required DateTime startsAt,
    required int durationMinutes,
    required int amountCents,
    required String currency,
  });

  Future<void> markPaid(String bookingId);
  Future<void> cancelBooking(String bookingId);
  Future<void> rescheduleBooking(String bookingId, DateTime newStartsAt);

  /// Admin-only status transition (e.g. mark completed).
  Future<void> updateStatus(String bookingId, BookingStatus status);
}

class FirestoreBookingsRepository implements BookingsRepository {
  FirestoreBookingsRepository(this._firestore);

  final FirebaseFirestore _firestore;
  final Logger _log = Logger('BookingsRepository');

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection('bookings');

  @override
  Stream<List<Booking>> watchUserBookings(String userId) {
    return _collection
        .where('userId', isEqualTo: userId)
        .orderBy('startsAt', descending: true)
        .snapshots()
        .map(_mapSnapshot);
  }

  @override
  Stream<List<Booking>> watchAllBookings() {
    return _collection
        .orderBy('startsAt', descending: true)
        .snapshots()
        .map(_mapSnapshot);
  }

  @override
  Stream<List<Booking>> watchBookingsForDay(DateTime day) {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    return _collection
        .where('startsAt', isGreaterThanOrEqualTo: Timestamp.fromDate(dayStart))
        .where('startsAt', isLessThan: Timestamp.fromDate(dayEnd))
        .where('status',
            whereIn: [BookingStatus.pending.name, BookingStatus.confirmed.name])
        .snapshots()
        .map(_mapSnapshot);
  }

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
    if (startsAt.isBefore(DateTime.now())) {
      throw const ValidationFailure('Choose a slot in the future.');
    }
    try {
      final booking = Booking(
        id: '', // assigned by Firestore
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
      final ref = await _collection.add(booking.toFirestore());
      _log.info('Created booking ${ref.id} for service $serviceId');
      return Booking.fromFirestore(ref.id, booking.toFirestore());
    } on FirebaseException catch (e) {
      _log.severe('createBooking failed', e);
      throw const UnexpectedFailure(
          'Could not create the booking. Please try again.');
    }
  }

  @override
  Future<void> markPaid(String bookingId) async {
    await _update(bookingId, {
      'paymentStatus': PaymentStatus.paid.name,
      'status': BookingStatus.confirmed.name,
    });
  }

  @override
  Future<void> cancelBooking(String bookingId) async {
    final booking = await _get(bookingId);
    if (!booking.canCancel) {
      throw const ValidationFailure(
        'This booking can no longer be cancelled. Please contact the business.',
      );
    }
    await _update(bookingId, {'status': BookingStatus.cancelled.name});
  }

  @override
  Future<void> rescheduleBooking(String bookingId, DateTime newStartsAt) async {
    final booking = await _get(bookingId);
    if (!booking.canReschedule) {
      throw const ValidationFailure(
        'This booking can no longer be rescheduled. Please contact the business.',
      );
    }
    if (newStartsAt.isBefore(DateTime.now())) {
      throw const ValidationFailure('Choose a slot in the future.');
    }
    await _update(bookingId, {'startsAt': Timestamp.fromDate(newStartsAt)});
  }

  @override
  Future<void> updateStatus(String bookingId, BookingStatus status) =>
      _update(bookingId, {'status': status.name});

  Future<Booking> _get(String bookingId) async {
    try {
      final doc = await _collection.doc(bookingId).get();
      if (!doc.exists || doc.data() == null) {
        throw const NotFoundFailure('This booking no longer exists.');
      }
      return Booking.fromFirestore(doc.id, doc.data()!);
    } on FirebaseException catch (e) {
      _log.severe('Failed to load booking $bookingId', e);
      throw const UnexpectedFailure(
          'Could not load the booking. Please try again.');
    }
  }

  Future<void> _update(String bookingId, Map<String, dynamic> data) async {
    try {
      await _collection.doc(bookingId).update(data);
      _log.info('Updated booking $bookingId: ${data.keys.join(', ')}');
    } on FirebaseException catch (e) {
      _log.severe('Failed to update booking $bookingId', e);
      throw const UnexpectedFailure('The update failed. Please try again.');
    }
  }

  List<Booking> _mapSnapshot(QuerySnapshot<Map<String, dynamic>> snapshot) {
    return snapshot.docs
        .map((doc) => Booking.fromFirestore(doc.id, doc.data()))
        .toList(growable: false);
  }
}
