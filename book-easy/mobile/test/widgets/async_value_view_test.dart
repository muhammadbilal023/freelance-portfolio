import 'package:book_easy/core/errors/failures.dart';
import 'package:book_easy/core/network/connectivity_service.dart';
import 'package:book_easy/core/widgets/async_value_view.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [view] with the connectivity plugin replaced by a fixed stream,
/// so tests never touch platform channels.
Future<void> pumpView(
  WidgetTester tester,
  AsyncValueView<String> view, {
  List<ConnectivityResult> connectivity = const [ConnectivityResult.wifi],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectivityStreamProvider
            .overrideWith((ref) => Stream.value(connectivity)),
      ],
      child: MaterialApp(home: Scaffold(body: view)),
    ),
  );
  await tester.pump(); // let the connectivity stream emit
}

AsyncValueView<String> buildView({
  required AsyncValue<String> value,
  bool Function(String data)? isEmpty,
  String emptyMessage = 'Nothing here yet.',
  VoidCallback? onRetry,
}) {
  return AsyncValueView<String>(
    value: value,
    builder: (data) => Center(child: Text(data)),
    isEmpty: isEmpty,
    emptyMessage: emptyMessage,
    onRetry: onRetry,
  );
}

void main() {
  group('AsyncValueView', () {
    testWidgets('shows a spinner while loading', (tester) async {
      await pumpView(tester, buildView(value: const AsyncValue.loading()));

      expect(find.byType(CircularProgressIndicator), findsOne);
    });

    testWidgets('renders the data builder when data arrives', (tester) async {
      await pumpView(tester, buildView(value: const AsyncValue.data('Hello')));

      expect(find.text('Hello'), findsOne);
    });

    testWidgets('shows the failure message and a Retry button on error',
        (tester) async {
      var retries = 0;
      await pumpView(
        tester,
        buildView(
          value: const AsyncValue.error(
              NetworkFailure('No connection.'), StackTrace.empty),
          onRetry: () => retries++,
        ),
      );

      expect(find.text('No connection.'), findsOne);
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      expect(retries, 1);
    });

    testWidgets('omits the Retry button when onRetry is null', (tester) async {
      await pumpView(
        tester,
        buildView(
            value: AsyncValue.error(StateError('boom'), StackTrace.empty)),
      );

      expect(find.text('Something went wrong.'), findsOne);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('shows the empty message when isEmpty matches', (tester) async {
      await pumpView(
        tester,
        buildView(
          value: const AsyncValue.data(''),
          isEmpty: (data) => data.isEmpty,
          emptyMessage: 'No bookings yet.',
        ),
      );

      expect(find.text('No bookings yet.'), findsOne);
    });

    testWidgets('shows the offline banner when connectivity is none',
        (tester) async {
      await pumpView(
        tester,
        buildView(value: const AsyncValue.data('cached')),
        connectivity: const [ConnectivityResult.none],
      );

      expect(find.byType(OfflineBanner), findsOne);
      expect(find.text('You are offline — showing cached data'), findsOne);
      expect(find.text('cached'), findsOne);
    });

    testWidgets('hides the offline banner while online', (tester) async {
      await pumpView(tester, buildView(value: const AsyncValue.data('live')));

      expect(find.byType(OfflineBanner), findsNothing);
    });
  });
}
