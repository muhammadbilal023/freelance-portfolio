import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_value_view.dart';
import '../domain/booking.dart';
import 'booking_providers.dart';

/// Booking history for the signed-in client, grouped into upcoming and past.
class BookingsHistoryScreen extends ConsumerWidget {
  const BookingsHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookingsAsync = ref.watch(userBookingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My bookings')),
      body: AsyncValueView(
        value: bookingsAsync,
        isEmpty: (data) => data.isEmpty,
        emptyMessage:
            'No bookings yet.\nBrowse services to make your first booking.',
        onRetry: () => ref.invalidate(userBookingsProvider),
        builder: (bookings) {
          final upcoming = bookings
              .where((b) => b.isUpcoming && b.status != BookingStatus.cancelled)
              .toList();
          final past = bookings
              .where(
                  (b) => !b.isUpcoming || b.status == BookingStatus.cancelled)
              .toList();

          return RefreshIndicator(
            onRefresh: () async => ref.refresh(userBookingsProvider.future),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (upcoming.isNotEmpty) ...[
                  const _SectionHeader('Upcoming'),
                  ...upcoming.map((b) => BookingTile(booking: b)),
                ],
                if (past.isNotEmpty) ...[
                  const _SectionHeader('Past & cancelled'),
                  ...past.map((b) => BookingTile(booking: b)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

/// One booking row with status chip; shared by history and admin screens.
class BookingTile extends StatelessWidget {
  const BookingTile({required this.booking, super.key, this.subtitleOverride});

  final Booking booking;
  final String? subtitleOverride;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        onTap: () => context.push('/booking/${booking.id}'),
        leading: CircleAvatar(
          backgroundColor:
              _statusColor(booking.status, theme).withValues(alpha: 0.2),
          child: Icon(_statusIcon(booking.status),
              color: _statusColor(booking.status, theme)),
        ),
        title: Text(booking.serviceName, style: theme.textTheme.titleMedium),
        subtitle: Text(
          subtitleOverride ??
              '${Formatters.date(booking.startsAt)} • ${Formatters.time(booking.startsAt)}\n'
                  '${Formatters.money(booking.amountCents, booking.currency)}',
        ),
        isThreeLine: subtitleOverride == null,
        trailing: _StatusChip(booking: booking),
      ),
    );
  }

  static Color _statusColor(BookingStatus status, ThemeData theme) {
    return switch (status) {
      BookingStatus.pending => theme.colorScheme.tertiary,
      BookingStatus.confirmed => theme.colorScheme.primary,
      BookingStatus.completed => theme.colorScheme.outline,
      BookingStatus.cancelled => theme.colorScheme.error,
    };
  }

  static IconData _statusIcon(BookingStatus status) {
    return switch (status) {
      BookingStatus.pending => Icons.hourglass_top,
      BookingStatus.confirmed => Icons.event_available,
      BookingStatus.completed => Icons.done_all,
      BookingStatus.cancelled => Icons.cancel_outlined,
    };
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.booking});

  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final label = switch (booking.status) {
      BookingStatus.pending => 'Pending payment',
      BookingStatus.confirmed => 'Confirmed',
      BookingStatus.completed => 'Completed',
      BookingStatus.cancelled => 'Cancelled',
    };
    final color = BookingTile._statusColor(booking.status, Theme.of(context));

    return Chip(
      label: Text(label, style: TextStyle(color: color, fontSize: 11)),
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
