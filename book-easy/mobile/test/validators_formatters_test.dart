import 'package:book_easy/core/utils/formatters.dart';
import 'package:book_easy/core/utils/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Validators.email', () {
    test('rejects empty and whitespace input', () {
      expect(Validators.email(''), 'Email is required');
      expect(Validators.email('   '), 'Email is required');
      expect(Validators.email(null), 'Email is required');
    });

    test('rejects malformed addresses', () {
      expect(Validators.email('not-an-email'), isNotNull);
      expect(Validators.email('a@b'), isNotNull);
      expect(Validators.email('a b@c.com'), isNotNull);
    });

    test('accepts valid addresses with trimming', () {
      expect(Validators.email('user@example.com'), isNull);
      expect(Validators.email('  user.name+tag@sub.example.co  '), isNull);
    });
  });

  group('Validators.password', () {
    test('enforces a minimum length of 8', () {
      expect(Validators.password(''), 'Password is required');
      expect(Validators.password('abc123'), isNotNull);
      expect(Validators.password('abcd1234'), isNull);
    });
  });

  group('Validators.displayName', () {
    test('bounds the length', () {
      expect(Validators.displayName(''), isNotNull);
      expect(Validators.displayName('A'), isNotNull);
      expect(Validators.displayName('Al'), isNull);
      expect(Validators.displayName('x' * 61), isNotNull);
    });
  });

  group('Validators.price', () {
    test('accepts positive decimals only', () {
      expect(Validators.price(''), isNotNull);
      expect(Validators.price('abc'), isNotNull);
      expect(Validators.price('0'), isNotNull);
      expect(Validators.price('-5'), isNotNull);
      expect(Validators.price('45.50'), isNull);
      expect(Validators.price('999999'), isNotNull);
    });
  });

  group('Validators.durationMinutes', () {
    test('requires multiples of 5 within 5..480', () {
      expect(Validators.durationMinutes('4'), isNotNull);
      expect(Validators.durationMinutes('481'), isNotNull);
      expect(Validators.durationMinutes('7'), isNotNull);
      expect(Validators.durationMinutes('45'), isNull);
      expect(Validators.durationMinutes(null), isNotNull);
    });
  });

  group('Formatters.money', () {
    test('formats minor units with the right symbol', () {
      expect(Formatters.money(4500, 'usd'), r'$45.00');
      expect(Formatters.money(4500, 'eur'), '€45.00');
      expect(Formatters.money(99, 'gbp'), '£0.99');
      expect(Formatters.money(100050, 'inr'), '₹1000.50');
    });

    test('falls back to the currency code for unknown currencies', () {
      expect(Formatters.money(100, 'chf'), 'chf 1.00');
    });
  });

  group('Formatters.duration', () {
    test('mixes hours and minutes', () {
      expect(Formatters.duration(45), '45min');
      expect(Formatters.duration(60), '1h');
      expect(Formatters.duration(90), '1h 30min');
    });
  });

  group('Formatters.slot', () {
    test('renders a start-end range', () {
      final start = DateTime(2026, 1, 5, 9);
      final end = DateTime(2026, 1, 5, 9, 45);
      expect(Formatters.slot(start, end), '09:00 – 09:45');
    });
  });
}
