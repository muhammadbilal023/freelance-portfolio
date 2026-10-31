import 'package:cloud_firestore/cloud_firestore.dart';

/// A booking of one service at one time slot. Stored in Firestore `bookings/{id}`.
class Booking {
  const Booking({
    required this.id,
    required this.userId,
    required this.serviceId,
    required this.serviceName,
    required this.startsAt,
    required this.durationMinutes,
    required this.amountCents,
    required this.currency,
    required this.status,
    required this.paymentStatus,
    this.customerName = '',
  });

  final String id;
  final String userId;
  final String serviceId;

  /// Denormalized for fast display in lists without extra reads.
  final String serviceName;
  final DateTime startsAt;
  final int durationMinutes;
  final int amountCents;
  final String currency;
  final BookingStatus status;
  final PaymentStatus paymentStatus;
  final String customerName;

  DateTime get endsAt => startsAt.add(Duration(minutes: durationMinutes));

  bool get isUpcoming => startsAt.isAfter(DateTime.now());

  /// Cancellation is free up to 24h before the slot; after that the business
  /// keeps the payment (policy enforced in the repository too).
  bool get canCancel =>
      status == BookingStatus.pending ||
      status == BookingStatus.confirmed &&
          startsAt.difference(DateTime.now()).inHours >= 24;

  bool get canReschedule => canCancel;

  factory Booking.fromFirestore(String id, Map<String, dynamic> data) {
    return Booking(
      id: id,
      userId: data['userId'] as String? ?? '',
      serviceId: data['serviceId'] as String? ?? '',
      serviceName: data['serviceName'] as String? ?? '',
      startsAt: (data['startsAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? 30,
      amountCents: (data['amountCents'] as num?)?.toInt() ?? 0,
      currency: data['currency'] as String? ?? 'usd',
      status: BookingStatus.fromString(data['status'] as String?),
      paymentStatus: PaymentStatus.fromString(data['paymentStatus'] as String?),
      customerName: data['customerName'] as String? ?? '',
    );
  }

  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'serviceId': serviceId,
        'serviceName': serviceName,
        'startsAt': Timestamp.fromDate(startsAt),
        'durationMinutes': durationMinutes,
        'amountCents': amountCents,
        'currency': currency,
        'status': status.name,
        'paymentStatus': paymentStatus.name,
        'customerName': customerName,
      };

  Booking copyWith({
    DateTime? startsAt,
    BookingStatus? status,
    PaymentStatus? paymentStatus,
  }) {
    return Booking(
      id: id,
      userId: userId,
      serviceId: serviceId,
      serviceName: serviceName,
      startsAt: startsAt ?? this.startsAt,
      durationMinutes: durationMinutes,
      amountCents: amountCents,
      currency: currency,
      status: status ?? this.status,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      customerName: customerName,
    );
  }
}

enum BookingStatus {
  /// Awaiting payment.
  pending,

  /// Paid and confirmed.
  confirmed,

  cancelled,
  completed;

  static BookingStatus fromString(String? value) =>
      BookingStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => BookingStatus.pending,
      );
}

enum PaymentStatus {
  unpaid,
  paid,
  refunded;

  static PaymentStatus fromString(String? value) =>
      PaymentStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => PaymentStatus.unpaid,
      );
}
