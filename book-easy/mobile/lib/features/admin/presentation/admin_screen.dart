import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../bookings/domain/booking.dart';
import '../../bookings/presentation/booking_providers.dart';
import 'service_form_sheet.dart';

/// Admin area: all bookings with status management + service catalog editor.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.event_note), text: 'Bookings'),
            Tab(icon: Icon(Icons.spa_outlined), text: 'Services'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        // Only relevant on the Services tab; hidden elsewhere.
        onPressed: () => ServiceFormSheet.show(context),
        child: const Icon(Icons.add),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [AdminBookingsTab(), AdminServicesTab()],
      ),
    );
  }
}

/// All bookings across customers with inline status transitions.
class AdminBookingsTab extends ConsumerWidget {
  const AdminBookingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookings = ref.watch(allBookingsProvider);

    return AsyncValueView(
      value: bookings,
      isEmpty: (data) => data.isEmpty,
      emptyMessage: 'No bookings yet.',
      onRetry: () => ref.invalidate(allBookingsProvider),
      builder: (data) => ListView.builder(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: data.length,
        itemBuilder: (context, index) {
          final booking = data[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: ListTile(
              title: Text('${booking.serviceName} — ${booking.customerName}'),
              subtitle: Text(
                '${Formatters.date(booking.startsAt)} • ${Formatters.time(booking.startsAt)}\n'
                '${Formatters.money(booking.amountCents, booking.currency)} • '
                'payment: ${booking.paymentStatus.name}',
              ),
              isThreeLine: true,
              trailing: _StatusMenu(booking: booking),
            ),
          );
        },
      ),
    );
  }
}

class _StatusMenu extends ConsumerWidget {
  const _StatusMenu({required this.booking});

  final Booking booking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<BookingStatus>(
      initialValue: booking.status,
      tooltip: 'Change status',
      icon: Chip(
        label: Text(booking.status.name, style: const TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onSelected: (status) async {
        final repository = ref.read(bookingsRepositoryProvider);
        final messenger = ScaffoldMessenger.of(context);
        try {
          await repository.updateStatus(booking.id, status);
          messenger.showSnackBar(
              SnackBar(content: Text('Marked as ${status.name}')));
        } catch (error) {
          messenger.showSnackBar(
            SnackBar(content: Text('Update failed: $error')),
          );
        }
      },
      itemBuilder: (context) => BookingStatus.values
          .where((s) => s != booking.status)
          .map((s) => PopupMenuItem(value: s, child: Text(s.name)))
          .toList(),
    );
  }
}
