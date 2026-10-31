import 'package:flutter/material.dart';

import '../../../../core/utils/formatters.dart';

/// Grid of selectable time slots for one day.
class SlotGrid extends StatelessWidget {
  const SlotGrid({
    required this.slots,
    required this.durationMinutes,
    required this.onSelect,
    super.key,
    this.selectedSlot,
  });

  final List<DateTime> slots;
  final int durationMinutes;
  final ValueChanged<DateTime> onSelect;
  final DateTime? selectedSlot;

  @override
  Widget build(BuildContext context) {
    if (slots.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text(
            'No free slots on this day.\nTry another date.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.2,
      ),
      itemCount: slots.length,
      itemBuilder: (context, index) {
        final slot = slots[index];
        final end = slot.add(Duration(minutes: durationMinutes));
        final isSelected = slot == selectedSlot;

        return OutlinedButton(
          key: ValueKey('slot_${slot.toIso8601String()}'),
          onPressed: () => onSelect(slot),
          style: OutlinedButton.styleFrom(
            backgroundColor: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
          ),
          child: Text(
            Formatters.slot(slot, end),
            style: const TextStyle(fontSize: 12),
          ),
        );
      },
    );
  }
}
