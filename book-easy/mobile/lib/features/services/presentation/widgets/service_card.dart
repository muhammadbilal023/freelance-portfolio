import 'package:flutter/material.dart';

import '../../../../core/utils/formatters.dart';
import '../../domain/service_item.dart';

/// Compact service summary used in lists (browse + admin screens).
class ServiceCard extends StatelessWidget {
  const ServiceCard({
    required this.service,
    super.key,
    this.onTap,
    this.trailing,
  });

  final ServiceItem service;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(_categoryIcon(service.category),
              color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(service.name, style: theme.textTheme.titleMedium),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${Formatters.duration(service.durationMinutes)} • '
            '${Formatters.money(service.priceCents, service.currency)}',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        trailing: trailing ??
            Icon(Icons.chevron_right, color: theme.colorScheme.outline),
      ),
    );
  }

  static IconData _categoryIcon(String category) {
    return switch (category.toLowerCase()) {
      'salon' || 'hair' => Icons.content_cut,
      'clinic' || 'health' => Icons.medical_services_outlined,
      'tutor' || 'education' => Icons.school_outlined,
      'fitness' => Icons.fitness_center_outlined,
      _ => Icons.spa_outlined,
    };
  }
}
