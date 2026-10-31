import 'package:book_easy/features/bookings/presentation/widgets/slot_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final slots = [
    DateTime(2026, 1, 5, 9),
    DateTime(2026, 1, 5, 9, 30),
    DateTime(2026, 1, 5, 10),
  ];

  Widget wrap(SlotGrid grid) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: grid)));

  group('SlotGrid', () {
    testWidgets('renders one button per slot with the time range label',
        (tester) async {
      await tester.pumpWidget(wrap(SlotGrid(
        slots: slots,
        durationMinutes: 30,
        onSelect: (_) {},
      )));

      expect(
          find.byKey(ValueKey('slot_${slots[0].toIso8601String()}')), findsOne);
      expect(find.text('09:00 – 09:30'), findsOne);
      expect(find.text('09:30 – 10:00'), findsOne);
      expect(find.text('10:00 – 10:30'), findsOne);
    });

    testWidgets('tapping a slot invokes onSelect with that slot',
        (tester) async {
      DateTime? selected;
      await tester.pumpWidget(wrap(SlotGrid(
        slots: slots,
        durationMinutes: 30,
        onSelect: (slot) => selected = slot,
      )));

      await tester
          .tap(find.byKey(ValueKey('slot_${slots[1].toIso8601String()}')));

      expect(selected, slots[1]);
    });

    testWidgets('shows the empty-state message when there are no slots',
        (tester) async {
      await tester.pumpWidget(wrap(SlotGrid(
        slots: const [],
        durationMinutes: 30,
        onSelect: (_) {},
      )));

      expect(
          find.text('No free slots on this day.\nTry another date.'), findsOne);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });
}
