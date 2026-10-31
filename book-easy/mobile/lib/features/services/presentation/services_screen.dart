import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/async_value_view.dart';
import '../presentation/services_providers.dart';
import '../presentation/widgets/service_card.dart';

/// Client-facing catalog of bookable services.
class ServicesScreen extends ConsumerWidget {
  const ServicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(activeServicesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Services')),
      body: AsyncValueView(
        value: services,
        isEmpty: (data) => data.isEmpty,
        emptyMessage: 'No services available yet.\nPlease check back soon.',
        onRetry: () => ref.invalidate(activeServicesProvider),
        builder: (data) => RefreshIndicator(
          onRefresh: () async => ref.refresh(activeServicesProvider.future),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: data.length,
            itemBuilder: (context, index) {
              final service = data[index];
              return ServiceCard(
                service: service,
                onTap: () => context.push('/service/${service.id}'),
              );
            },
          ),
        ),
      ),
    );
  }
}
