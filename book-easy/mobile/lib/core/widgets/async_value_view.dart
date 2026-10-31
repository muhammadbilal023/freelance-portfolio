import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/failures.dart';
import '../network/connectivity_service.dart';

/// Renders the four canonical async UI states — loading, error, empty, data —
/// in one place so every screen behaves consistently.
///
/// [value] typically comes from `ref.watch(someStreamProvider)`.
/// [isEmpty] lets a feature decide what "empty" means for its data type.
class AsyncValueView<T> extends ConsumerWidget {
  const AsyncValueView({
    required this.value,
    required this.builder,
    super.key,
    this.isEmpty,
    this.emptyMessage = 'Nothing here yet.',
    this.onRetry,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final bool Function(T data)? isEmpty;
  final String emptyMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = !ref.watch(isOnlineProvider);

    return Column(
      children: [
        if (isOffline) const OfflineBanner(),
        Expanded(child: _buildContent(context)),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    return value.when(
      // Keep showing stale data (with the offline banner) instead of
      // flashing an error screen when connectivity drops.
      skipLoadingOnRefresh: true,
      data: (data) {
        if (data != null && isEmpty != null && isEmpty!(data)) {
          return _EmptyState(message: emptyMessage);
        }
        return builder(data);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ErrorState(
        message: error is Failure ? error.message : 'Something went wrong.',
        onRetry: onRetry,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 56, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Thin banner shown at the top of a screen while the device is offline.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Text(
            'You are offline — showing cached data',
            style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
