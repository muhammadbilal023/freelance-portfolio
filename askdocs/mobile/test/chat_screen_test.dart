import 'dart:async';

import 'package:askdocs_mobile/api.dart';
import 'package:askdocs_mobile/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted fake: replays a canned SSE event sequence and records feedback.
class FakeAskDocsApi implements AskDocsApi {
  FakeAskDocsApi(this.script);

  final List<StreamEvent> script;
  final List<(int, String)> feedback = [];
  String? lastQuestion;
  String? lastSessionId;

  @override
  Stream<StreamEvent> streamChat({
    required String question,
    required String sessionId,
    required String userId,
  }) {
    lastQuestion = question;
    lastSessionId = sessionId;
    return Stream.fromIterable(script);
  }

  @override
  Future<void> sendFeedback({
    required int messageId,
    required String rating,
    required String userId,
  }) async {
    feedback.add((messageId, rating));
  }
}

Widget _app(AskDocsApi api) =>
    MaterialApp(home: ChatScreen(api: api, userId: 'tester'));

void main() {
  testWidgets('streams an answer, shows citation, and finishes',
      (tester) async {
    final api = FakeAskDocsApi(const [
      SessionEvent('sess-1'),
      CitationsEvent([Citation(id: 1, fileName: 'returns.txt', page: 1)]),
      TokenEvent('Refunds take '),
      TokenEvent('five days [S1].'),
      DoneEvent(
          messageId: 42, needsHandoff: false, ungrounded: false, citations: []),
    ]);

    await tester.pumpWidget(_app(api));
    await tester.enterText(find.byType(TextField), 'How long for a refund?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    // The full answer text is present after the token stream completes.
    expect(find.textContaining('Refunds take five days [S1].'), findsOneWidget);
    // Citation chip is rendered.
    expect(find.textContaining('returns.txt'), findsOneWidget);
    // Session id was captured for continuity on the next turn.
    expect(api.lastSessionId, isEmpty); // first turn started with ""
    // Feedback controls appear under the assistant answer.
    expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
    expect(find.byIcon(Icons.thumb_down_alt_outlined), findsOneWidget);
  });

  testWidgets('feedback tap calls the api', (tester) async {
    final api = FakeAskDocsApi(const [
      SessionEvent('sess-2'),
      TokenEvent('We ship on weekdays [S1].'),
      DoneEvent(
          messageId: 7, needsHandoff: false, ungrounded: false, citations: []),
    ]);

    await tester.pumpWidget(_app(api));
    await tester.enterText(find.byType(TextField), 'Do you ship?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
    await tester.pumpAndSettle();

    expect(api.feedback, contains((7, 'helpful')));
  });

  testWidgets('error event surfaces an inline message', (tester) async {
    final api = FakeAskDocsApi(const [
      SessionEvent('sess-3'),
      ErrorEvent('Slow down — too many requests.'),
    ]);

    await tester.pumpWidget(_app(api));
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.textContaining('too many requests'), findsOneWidget);
  });
}
