import 'package:book_easy/features/services/domain/service_item.dart';
import 'package:book_easy/features/services/presentation/widgets/service_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = ServiceItem(
    id: 's1',
    name: 'Haircut',
    description: 'Classic cut',
    category: 'Salon',
    durationMinutes: 45,
    priceCents: 4500,
  );

  Widget wrap(ServiceCard card) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: card)));

  group('ServiceCard', () {
    testWidgets('shows the service name, duration and formatted price',
        (tester) async {
      await tester.pumpWidget(wrap(const ServiceCard(service: service)));

      expect(find.text('Haircut'), findsOne);
      expect(find.text('45min • \$45.00'), findsOne);
    });

    testWidgets('uses the salon icon for the salon category', (tester) async {
      await tester.pumpWidget(wrap(const ServiceCard(service: service)));

      expect(find.byIcon(Icons.content_cut), findsOne);
    });

    testWidgets('tapping the card invokes onTap', (tester) async {
      var taps = 0;
      await tester
          .pumpWidget(wrap(ServiceCard(service: service, onTap: () => taps++)));

      await tester.tap(find.byType(ListTile));

      expect(taps, 1);
    });

    testWidgets('renders a custom trailing widget when provided',
        (tester) async {
      await tester.pumpWidget(wrap(const ServiceCard(
        service: service,
        trailing: Icon(Icons.edit_outlined),
      )));

      expect(find.byIcon(Icons.edit_outlined), findsOne);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });
  });
}
