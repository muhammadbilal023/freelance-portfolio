import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../../core/errors/failures.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../services/presentation/services_providers.dart';
import 'booking_providers.dart';
import 'widgets/slot_grid.dart';

/// Booking flow: pick a day on the calendar, pick a free slot, confirm and
/// pay through the Stripe sheet. Handles success, cancelled and failure
/// outcomes explicitly.
class BookingFlowScreen extends ConsumerStatefulWidget {
  const BookingFlowScreen({required this.serviceId, super.key});

  final String serviceId;

  @override
  ConsumerState<BookingFlowScreen> createState() => _BookingFlowScreenState();
}

class _BookingFlowScreenState extends ConsumerState<BookingFlowScreen> {
  DateTime _selectedDay = _normalize(DateTime.now());
  DateTime? _selectedSlot;
  bool _isCheckingOut = false;

  static DateTime _normalize(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context) {
    final serviceAsync = ref.watch(serviceProvider(widget.serviceId));
    final today = _normalize(DateTime.now());

    return Scaffold(
      appBar: AppBar(title: const Text('Choose a time')),
      body: AsyncValueView(
        value: serviceAsync,
        onRetry: () => ref.invalidate(serviceProvider(widget.serviceId)),
        builder: (service) {
          final slotsAsync = ref.watch(
            availableSlotsProvider(
                (serviceId: widget.serviceId, day: _selectedDay)),
          );

          return ListView(
            children: [
              TableCalendar(
                firstDay: today,
                lastDay: today.add(const Duration(days: 60)),
                focusedDay: _selectedDay,
                startingDayOfWeek: StartingDayOfWeek.monday,
                selectedDayPredicate: (day) => _normalize(day) == _selectedDay,
                enabledDayPredicate: (day) => day.weekday != DateTime.sunday,
                onDaySelected: (selected, _) => setState(() {
                  _selectedDay = _normalize(selected);
                  _selectedSlot = null;
                }),
                calendarStyle: CalendarStyle(
                  todayDecoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  selectedDecoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Available slots — ${Formatters.date(_selectedDay)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              slotsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      error is Failure
                          ? error.message
                          : 'Could not load slots.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                data: (slots) => SlotGrid(
                  slots: slots,
                  durationMinutes: service.durationMinutes,
                  selectedSlot: _selectedSlot,
                  onSelect: (slot) => setState(() => _selectedSlot = slot),
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed:
                _selectedSlot == null || _isCheckingOut ? null : _confirmAndPay,
            child: _isCheckingOut
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Confirm & pay'),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmAndPay() async {
    final service = ref.read(serviceProvider(widget.serviceId)).valueOrNull;
    final user = ref.read(currentUserProvider);
    final slot = _selectedSlot;
    if (service == null || user == null || slot == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm booking'),
        content: Text(
          '${service.name}\n'
          '${Formatters.date(slot)} at ${Formatters.time(slot)}\n'
          '${Formatters.money(service.priceCents, service.currency)}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Back')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Pay now')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isCheckingOut = true);
    final result = await ref.read(bookingControllerProvider).checkout(
          user: user,
          service: service,
          slot: slot,
        );
    if (!mounted) return;
    setState(() => _isCheckingOut = false);

    await _showCheckoutResult(result);
  }

  Future<void> _showCheckoutResult(CheckoutResult result) async {
    switch (result) {
      case CheckoutSuccess(:final booking):
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.check_circle_outline, size: 48),
            title: const Text('Booking confirmed!'),
            content: Text(
              'Your ${booking.serviceName} booking is paid and confirmed. '
              'We will remind you before your appointment.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        );
        if (mounted) {
          // Replace the flow so Back doesn't re-enter a finished checkout.
          context.go('/bookings');
        }
      case CheckoutCancelled(:final pendingBooking):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Payment cancelled. Your booking is held as pending.'),
            action: SnackBarAction(
              label: 'VIEW',
              onPressed: () => context.push('/booking/${pendingBooking.id}'),
            ),
          ),
        );
      case CheckoutFailure(:final failure, :final pendingBooking):
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            title: const Text('Payment failed'),
            content: Text(
              pendingBooking == null
                  ? failure.message
                  : '${failure.message}\n\n'
                      'Your booking is saved as pending — you can retry payment '
                      'from your booking history.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
    }
  }
}
