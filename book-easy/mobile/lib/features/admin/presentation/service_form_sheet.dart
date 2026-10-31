import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../services/domain/service_item.dart';
import '../../services/presentation/services_providers.dart';

/// Add/edit form for a service, shown as a modal bottom sheet.
/// Returns true when the service was saved.
class ServiceFormSheet extends ConsumerStatefulWidget {
  const ServiceFormSheet({super.key, this.existing});

  /// Null when creating a new service.
  final ServiceItem? existing;

  static Future<bool?> show(BuildContext context, {ServiceItem? existing}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        // Keep fields above the soft keyboard.
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ServiceFormSheet(existing: existing),
      ),
    );
  }

  @override
  ConsumerState<ServiceFormSheet> createState() => _ServiceFormSheetState();
}

class _ServiceFormSheetState extends ConsumerState<ServiceFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name);
  late final TextEditingController _description =
      TextEditingController(text: widget.existing?.description);
  late final TextEditingController _category =
      TextEditingController(text: widget.existing?.category);
  late final TextEditingController _duration =
      TextEditingController(text: widget.existing?.durationMinutes.toString());
  late final TextEditingController _price = TextEditingController(
    text: widget.existing == null
        ? ''
        : (widget.existing!.priceCents / 100).toStringAsFixed(2),
  );
  late bool _isActive = widget.existing?.isActive ?? true;
  bool _isSaving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _category.dispose();
    _duration.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final priceCents = ((double.parse(_price.text.trim())) * 100).round();
    final service = ServiceItem(
      id: widget.existing?.id ?? '',
      name: _name.text.trim(),
      description: _description.text.trim(),
      category: _category.text.trim(),
      durationMinutes: int.parse(_duration.text.trim()),
      priceCents: priceCents,
      currency: widget.existing?.currency ?? 'usd',
      isActive: _isActive,
    );

    setState(() => _isSaving = true);
    try {
      await ref.read(servicesRepositoryProvider).saveService(service);
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isNew ? 'New service' : 'Edit service',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) =>
                  (v == null || v.trim().length < 2) ? 'Enter a name' : null,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 2,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Enter a description'
                  : null,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _category,
              decoration: const InputDecoration(
                labelText: 'Category',
                helperText: 'e.g. Salon, Clinic, Tutor',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Enter a category' : null,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _duration,
                    decoration: const InputDecoration(labelText: 'Minutes'),
                    keyboardType: TextInputType.number,
                    validator: Validators.durationMinutes,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _price,
                    decoration: const InputDecoration(labelText: 'Price'),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    validator: Validators.price,
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Visible to clients'),
              value: _isActive,
              onChanged: (value) => setState(() => _isActive = value),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isNew ? 'Create service' : 'Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Admin tab listing all services (including inactive) with quick toggles.
class AdminServicesTab extends ConsumerWidget {
  const AdminServicesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(allServicesProvider);

    return AsyncValueView(
      value: services,
      isEmpty: (data) => data.isEmpty,
      emptyMessage: 'No services yet — tap + to create the first one.',
      onRetry: () => ref.invalidate(allServicesProvider),
      builder: (data) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: data.length,
        itemBuilder: (context, index) {
          final service = data[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: ListTile(
              title: Text(service.name),
              subtitle: Text(
                '${Formatters.duration(service.durationMinutes)} • '
                '${Formatters.money(service.priceCents, service.currency)}',
              ),
              trailing: Switch(
                value: service.isActive,
                onChanged: (value) async {
                  await ref
                      .read(servicesRepositoryProvider)
                      .saveService(service.copyWith(isActive: value));
                },
              ),
              onTap: () => ServiceFormSheet.show(context, existing: service),
            ),
          );
        },
      ),
    );
  }
}
