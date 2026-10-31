import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_value_view.dart';
import 'services_providers.dart';

/// Full description of one service plus the entry point into booking.
class ServiceDetailScreen extends ConsumerWidget {
  const ServiceDetailScreen({required this.serviceId, super.key});

  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serviceAsync = ref.watch(serviceProvider(serviceId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Service')),
      body: AsyncValueView(
        value: serviceAsync,
        onRetry: () => ref.invalidate(serviceProvider(serviceId)),
        builder: (service) => ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(service.name, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(service.category, style: theme.textTheme.labelLarge),
            const SizedBox(height: 16),
            Row(
              children: [
                _InfoChip(
                  icon: Icons.schedule,
                  label: Formatters.duration(service.durationMinutes),
                ),
                const SizedBox(width: 8),
                _InfoChip(
                  icon: Icons.payments_outlined,
                  label: Formatters.money(service.priceCents, service.currency),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(service.description, style: theme.textTheme.bodyLarge),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            icon: const Icon(Icons.event_available),
            label: const Text('Book now'),
            onPressed: serviceAsync.valueOrNull == null
                ? null
                : () => context.push('/book/$serviceId'),
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
