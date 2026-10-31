/// Pure scheduling logic — no Firebase, no Flutter. Fully unit-testable.
///
/// Business rules encoded here:
///  * Opening hours: 09:00–17:00 local time, closed on Sundays.
///  * Slots start on 30-minute boundaries.
///  * A service must fit entirely inside opening hours.
///  * A slot must not overlap any existing (pending/confirmed) booking.
///  * A slot must start at least [leadTime] after "now" (default 1 hour) so
///    the business has preparation time.
class AvailabilityService {
  const AvailabilityService();

  static const int openHour = 9;
  static const int closeHour = 17;
  static const int slotStepMinutes = 30;
  static const Duration leadTime = Duration(hours: 1);

  /// True when the business is open on [day] (closed Sundays).
  bool isOpen(DateTime day) => day.weekday != DateTime.sunday;

  /// Returns the sorted list of bookable slot start times for [day].
  ///
  /// [busyPeriods] are the (start, end) intervals of existing bookings.
  List<DateTime> availableSlots({
    required DateTime day,
    required int durationMinutes,
    required List<(DateTime, DateTime)> busyPeriods,
    DateTime? now,
  }) {
    if (!isOpen(day) || durationMinutes <= 0) return const [];

    final effectiveNow = now ?? DateTime.now();
    final earliestStart = effectiveNow.add(leadTime);

    final dayOpen = DateTime(day.year, day.month, day.day, openHour);
    final dayClose = DateTime(day.year, day.month, day.day, closeHour);

    final slots = <DateTime>[];
    for (var start = dayOpen;
        start.add(Duration(minutes: durationMinutes)).isBefore(dayClose) ||
            start
                .add(Duration(minutes: durationMinutes))
                .isAtSameMomentAs(dayClose);
        start = start.add(const Duration(minutes: slotStepMinutes))) {
      final end = start.add(Duration(minutes: durationMinutes));

      if (start.isBefore(earliestStart)) continue;
      if (_overlapsAny(start, end, busyPeriods)) continue;

      slots.add(start);
    }
    return slots;
  }

  bool _overlapsAny(
    DateTime start,
    DateTime end,
    List<(DateTime, DateTime)> busyPeriods,
  ) {
    return busyPeriods.any((busy) {
      final (busyStart, busyEnd) = busy;
      // Two intervals overlap iff one starts before the other ends.
      return start.isBefore(busyEnd) && busyStart.isBefore(end);
    });
  }
}
