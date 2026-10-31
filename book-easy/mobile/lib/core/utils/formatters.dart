import 'package:intl/intl.dart';

/// Display formatting helpers shared across features.
class Formatters {
  const Formatters._();

  /// 4500 cents USD -> "$45.00".
  static String money(int amountCents, String currencyCode) {
    final symbol = switch (currencyCode.toLowerCase()) {
      'usd' => '\$',
      'eur' => '€',
      'gbp' => '£',
      'inr' => '₹',
      'aud' => 'A\$',
      'cad' => 'C\$',
      _ => '$currencyCode ',
    };
    final value = amountCents / 100.0;
    return '$symbol${value.toStringAsFixed(2)}';
  }

  static String date(DateTime day) => DateFormat('EEE, d MMM yyyy').format(day);

  static String time(DateTime moment) => DateFormat('HH:mm').format(moment);

  /// "09:00 – 09:45"
  static String slot(DateTime start, DateTime end) =>
      '${time(start)} – ${time(end)}';

  static String duration(int minutes) {
    if (minutes < 60) return '${minutes}min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}min';
  }
}
