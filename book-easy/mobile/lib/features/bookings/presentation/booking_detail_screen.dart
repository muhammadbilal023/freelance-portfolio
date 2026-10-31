import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failures.dart';
import '../../../core/utils/formatters.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/availability_service.dart';
import '../domain/booking.dart';
import 'booking_providers.dart';

/// Looks a booking up by id from the user's own list, falling back to the
/// admin list (the admin stream is only watched for admins).
final bookingByIdProvider =
    Provider.family<AsyncValue<Booking?>, String>((ref, id) {
  final mine = ref.watch(userBookingsProvider);
  final found = mine.valueOrNull?.where((b) => b.id == id);
  if (found != null && found.isNotEmpty) return AsyncValue.data(found.first);

  if (ref.watch(isAdminProvider)) {
    final all = ref.watch(allBookingsProvider);
    if (all.isLoading) return const AsyncValue.loading();
    final match = all.valueOrNull?.where((b) => b.id == id);
    if (match != null && match.isNotEmpty) return AsyncValue.data(match.first);
  }

  if (mine.isLoading) return const AsyncValue.loading();
  return const AsyncValue.data(null);
});

/// Details of one booking with contextual actions:
/// retry payment (pending), cancel and reschedule.
class BookingDetailScreen extends ConsumerStatefulWidget {
  const BookingDetailScreen({required this.bookingId, super.key});

  final String bookingId;

  @override
  ConsumerState<BookingDetailScreen> createState() =>
      _BookingDetailScreenState();
}

class _BookingDetailScreenState extends ConsumerState<BookingDetailScreen> {
  bool _isBusy = false;

  @override
  Widget build(BuildContext context) {
    final bookingAsync = ref.watch(bookingByIdProvider(widget.bookingId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Booking')),
      body: bookingAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text(
              error is Failure ? error.message : 'Could not load the booking.'),
        ),
        data: (booking) {
          if (booking == null) {
            return const Center(child: Text('This booking no longer exists.'));
          }
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(booking.serviceName, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 16),
              _DetailRow(
                  icon: Icons.calendar_today,
                  label: 'Date',
                  value: Formatters.date(booking.startsAt)),
              _DetailRow(
                  icon: Icons.schedule,
                  label: 'Time',
                  value: Formatters.slot(booking.startsAt, booking.endsAt)),
              _DetailRow(
                  icon: Icons.confirmation_number,
                  label: 'Status',
                  value: booking.status.name),
              _DetailRow(
                  icon: Icons.payments_outlined,
                  label: 'Payment',
                  value: booking.paymentStatus.name),
              _DetailRow(
                icon: Icons.receipt_long,
                label: 'Amount',
                value: Formatters.money(booking.amountCents, booking.currency),
              ),
              if (booking.userId != ref.watch(currentUserProvider)?.uid)
                _DetailRow(
                    icon: Icons.person,
                    label: 'Customer',
                    value: booking.customerName),
              const SizedBox(height: 32),
              ..._buildActions(booking),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildActions(Booking booking) {
    final isActive = booking.status == BookingStatus.pending ||
        booking.status == BookingStatus.confirmed;
    if (!isActive) return const [];

    return [
      if (booking.status == BookingStatus.pending &&
          booking.paymentStatus == PaymentStatus.unpaid)
        FilledButton.icon(
          onPressed: _isBusy ? null : () => _retryPayment(booking),
          icon: const Icon(Icons.lock_outline),
          label: const Text('Pay now'),
        ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _isBusy || !booking.canReschedule
            ? null
            : () => _reschedule(booking),
        icon: const Icon(Icons.swap_horiz),
        label: const Text('Reschedule'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed:
            _isBusy || !booking.canCancel ? null : () => _cancel(booking),
        icon: const Icon(Icons.cancel_outlined),
        label: const Text('Cancel booking'),
        style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error),
      ),
      if (!booking.canCancel)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Cancellation is only possible up to 24 hours before the appointment.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ];
  }

  Future<void> _retryPayment(Booking booking) async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;

    setState(() => _isBusy = true);
    final result = await ref
        .read(bookingControllerProvider)
        .payForBooking(booking, user: user);
    if (!mounted) return;
    setState(() => _isBusy = false);

    switch (result) {
      case CheckoutSuccess():
        _showSnack('Payment successful — your booking is confirmed!',
            isError: false);
      case CheckoutCancelled():
        _showSnack('Payment cancelled.', isError: false);
      case CheckoutFailure(:final failure):
        _showSnack(failure.message, isError: true);
    }
  }

  Future<void> _cancel(Booking booking) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel booking?'),
        content: Text(
          'Your ${booking.serviceName} appointment on '
          '${Formatters.date(booking.startsAt)} will be cancelled.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isBusy = true);
    try {
      await ref.read(bookingsRepositoryProvider).cancelBooking(booking.id);
      await ref
          .read(fcmServiceProvider)
          .unsubscribeFromBookingReminders(booking.id);
      if (mounted) _showSnack('Booking cancelled.', isError: false);
    } on Failure catch (failure) {
      if (mounted) _showSnack(failure.message, isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// Date + time picker flow, validated against real availability before
  /// writing to Firestore so a reschedule can never double-book a slot.
  Future<void> _reschedule(Booking booking) async {
    final availability = ref.read(availabilityServiceProvider);
    final today = DateTime.now();

    final day = await showDatePicker(
      context: context,
      initialDate: booking.startsAt.isAfter(today)
          ? booking.startsAt
          : today.add(const Duration(days: 1)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 60)),
      selectableDayPredicate: availability.isOpen,
    );
    if (day == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(booking.startsAt),
    );
    if (time == null || !mounted) return;

    // Snap the picked time down to the 30-minute slot grid.
    final requested = DateTime(
      day.year,
      day.month,
      day.day,
      time.hour,
      (time.minute ~/ AvailabilityService.slotStepMinutes) *
          AvailabilityService.slotStepMinutes,
    );

    setState(() => _isBusy = true);
    try {
      final dayBookings = await ref
          .read(bookingsRepositoryProvider)
          .watchBookingsForDay(day)
          .first;
      final busy = dayBookings
          .where((b) => b.serviceId == booking.serviceId && b.id != booking.id)
          .map((b) => (b.startsAt, b.endsAt))
          .toList(growable: false);
      final freeSlots = availability.availableSlots(
        day: day,
        durationMinutes: booking.durationMinutes,
        busyPeriods: busy,
      );

      if (!freeSlots.contains(requested)) {
        if (mounted) {
          _showSnack(
            'That slot is not available. Please pick another time.',
            isError: true,
          );
        }
        return;
      }

      await ref
          .read(bookingsRepositoryProvider)
          .rescheduleBooking(booking.id, requested);
      if (mounted) _showSnack('Booking rescheduled.', isError: false);
    } on Failure catch (failure) {
      if (mounted) _showSnack(failure.message, isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _showSnack(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(
      {required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.outline),
          const SizedBox(width: 12),
          SizedBox(
              width: 90, child: Text(label, style: theme.textTheme.bodyMedium)),
          Expanded(
            child: Text(
              value.substring(0, 1).toUpperCase() + value.substring(1),
              style: theme.textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}
