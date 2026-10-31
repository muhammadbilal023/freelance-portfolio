import 'package:book_easy/features/bookings/domain/availability_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const availability = AvailabilityService();

  // A fixed "now" keeps the lead-time rules deterministic.
  // Monday 2026-01-05, 08:00 local.
  final mondayMorning = DateTime(2026, 1, 5, 8);

  group('isOpen', () {
    test('closed on Sundays', () {
      expect(availability.isOpen(DateTime(2026, 1, 4)), isFalse);
    });

    test('open Monday to Saturday', () {
      for (var day = 5; day <= 10; day++) {
        expect(availability.isOpen(DateTime(2026, 1, day)), isTrue);
      }
    });
  });

  group('availableSlots', () {
    test('returns empty list on Sundays', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 4),
        durationMinutes: 30,
        busyPeriods: const [],
        now: mondayMorning,
      );
      expect(slots, isEmpty);
    });

    test('30-minute service fills 09:00-17:00 with 16 slots on a free day', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 5),
        durationMinutes: 30,
        busyPeriods: const [],
        now: mondayMorning,
      );
      expect(slots, hasLength(16));
      expect(slots.first, DateTime(2026, 1, 5, 9));
      expect(slots.last, DateTime(2026, 1, 5, 16, 30));
    });

    test('60-minute service must fit entirely inside opening hours', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 5),
        durationMinutes: 60,
        busyPeriods: const [],
        now: mondayMorning,
      );
      // Last valid start is 16:00 (ends exactly at 17:00 close).
      expect(slots.last, DateTime(2026, 1, 5, 16));
      expect(slots, hasLength(15));
    });

    test('busy periods remove every overlapping slot', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 5),
        durationMinutes: 30,
        busyPeriods: [(DateTime(2026, 1, 5, 10), DateTime(2026, 1, 5, 11))],
        now: mondayMorning,
      );
      expect(slots, isNot(contains(DateTime(2026, 1, 5, 10))));
      expect(slots, isNot(contains(DateTime(2026, 1, 5, 10, 30))));
      expect(slots, hasLength(14));
    });

    test('a booking ending exactly at slot start does not block it', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 5),
        durationMinutes: 30,
        busyPeriods: [(DateTime(2026, 1, 5, 9), DateTime(2026, 1, 5, 10))],
        now: mondayMorning,
      );
      expect(slots, contains(DateTime(2026, 1, 5, 10)));
    });

    test('long service partially overlapping a booking is excluded', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 5),
        durationMinutes: 90,
        busyPeriods: [(DateTime(2026, 1, 5, 10), DateTime(2026, 1, 5, 11))],
        now: mondayMorning,
      );
      // 09:00-10:30 overlaps the 10:00 booking start.
      expect(slots, isNot(contains(DateTime(2026, 1, 5, 9))));
      expect(slots, isNot(contains(DateTime(2026, 1, 5, 9, 30))));
      // 11:00-12:30 starts exactly when the booking ends — allowed.
      expect(slots, contains(DateTime(2026, 1, 5, 11)));
    });

    test('lead time hides slots starting within the next hour', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 5),
        durationMinutes: 30,
        busyPeriods: const [],
        now: DateTime(2026, 1, 5, 12),
      );
      // Earliest allowed start is 13:00.
      expect(slots.first, DateTime(2026, 1, 5, 13));
      expect(slots, isNot(contains(DateTime(2026, 1, 5, 12, 30))));
    });

    test('late in the day leaves no slots', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 5),
        durationMinutes: 30,
        busyPeriods: const [],
        now: DateTime(2026, 1, 5, 17),
      );
      expect(slots, isEmpty);
    });

    test('invalid duration yields no slots', () {
      final slots = availability.availableSlots(
        day: DateTime(2026, 1, 5),
        durationMinutes: 0,
        busyPeriods: const [],
        now: mondayMorning,
      );
      expect(slots, isEmpty);
    });
  });
}
