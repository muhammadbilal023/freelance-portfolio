/// Client for the AskDocs chat API.
///
/// [AskDocsApi] is an interface so the UI can be widget-tested with a fake that
/// emits a scripted event stream (no network). [HttpAskDocsApi] consumes the
/// server-sent-events from `POST /chat/stream` exactly as the web UI does.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Backend base URL; override at build time with
/// `--dart-define=BASE_URL=https://your-host`.
const String kBaseUrl =
    String.fromEnvironment('BASE_URL', defaultValue: 'http://localhost:8090');

class Citation {
  const Citation(
      {required this.id, required this.fileName, required this.page});
  final int id;
  final String fileName;
  final int page;

  factory Citation.fromJson(Map<String, dynamic> json) => Citation(
        id: json['id'] as int,
        fileName: json['file_name'] as String,
        page: json['page'] as int,
      );

  String get label => '[S$id] $fileName · p$page';
}

/// One streamed event. Kept as a tagged union for exhaustive UI handling.
sealed class StreamEvent {
  const StreamEvent();
}

class SessionEvent extends StreamEvent {
  const SessionEvent(this.sessionId);
  final String sessionId;
}

class TokenEvent extends StreamEvent {
  const TokenEvent(this.text);
  final String text;
}

class CitationsEvent extends StreamEvent {
  const CitationsEvent(this.citations);
  final List<Citation> citations;
}

class DoneEvent extends StreamEvent {
  const DoneEvent({
    required this.messageId,
    required this.needsHandoff,
    required this.ungrounded,
    required this.citations,
  });
  final int messageId;
  final bool needsHandoff;
  final bool ungrounded;
  final List<Citation> citations;
}

class HandoffEvent extends StreamEvent {
  const HandoffEvent(this.jobId);
  final int? jobId;
}

class ErrorEvent extends StreamEvent {
  const ErrorEvent(this.message);
  final String message;
}

abstract class AskDocsApi {
  Stream<StreamEvent> streamChat({
    required String question,
    required String sessionId,
    required String userId,
  });

  Future<void> sendFeedback(
      {required int messageId, required String rating, required String userId});
}

class HttpAskDocsApi implements AskDocsApi {
  HttpAskDocsApi({http.Client? client, String baseUrl = kBaseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl;

  final http.Client _client;
  final String _baseUrl;

  @override
  Stream<StreamEvent> streamChat({
    required String question,
    required String sessionId,
    required String userId,
  }) async* {
    final request = http.Request('POST', Uri.parse('$_baseUrl/chat/stream'))
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        'X-User-Id': userId,
      })
      ..body = jsonEncode({'question': question, 'session_id': sessionId});

    http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (e) {
      yield ErrorEvent('Network error: $e');
      return;
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      yield ErrorEvent(_errorMessage(response.statusCode, body));
      return;
    }

    // Decode the byte stream to text and split into SSE frames on blank lines.
    final buffered = _SseFrameSplitter();
    try {
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        for (final frame in buffered.push(chunk)) {
          final event = _parseFrame(frame);
          if (event != null) yield event;
        }
      }
      for (final frame in buffered.flush()) {
        final event = _parseFrame(frame);
        if (event != null) yield event;
      }
    } catch (e) {
      yield ErrorEvent('Stream error: $e');
    }
  }

  @override
  Future<void> sendFeedback({
    required int messageId,
    required String rating,
    required String userId,
  }) async {
    final resp = await _client.post(
      Uri.parse('$_baseUrl/feedback'),
      headers: {'Content-Type': 'application/json', 'X-User-Id': userId},
      body: jsonEncode({'message_id': messageId, 'rating': rating}),
    );
    if (resp.statusCode >= 400) {
      throw http.ClientException('Feedback failed: ${resp.statusCode}');
    }
  }

  StreamEvent? _parseFrame(String frame) {
    String? event;
    final dataLines = <String>[];
    for (final line in frame.split('\n')) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trim());
      }
    }
    if (event == null || dataLines.isEmpty) return null;
    final data = dataLines.join('\n');
    dynamic json;
    try {
      json = jsonDecode(data);
    } catch (_) {
      return null;
    }
    // The `citations` event is a bare JSON array; every other event is an object.
    if (event == 'citations') {
      final list = json as List;
      return CitationsEvent(
        list.map((c) => Citation.fromJson(c as Map<String, dynamic>)).toList(),
      );
    }
    final map = json as Map<String, dynamic>;
    switch (event) {
      case 'session':
        return SessionEvent(map['session_id'] as String);
      case 'token':
        return TokenEvent(map['text'] as String);
      case 'done':
        return DoneEvent(
          messageId: map['message_id'] as int,
          needsHandoff: map['needs_handoff'] as bool,
          ungrounded: map['ungrounded'] as bool? ?? false,
          citations: ((map['citations'] as List?) ?? const [])
              .map((c) => Citation.fromJson(c as Map<String, dynamic>))
              .toList(),
        );
      case 'handoff':
        return HandoffEvent(map['job_id'] as int?);
      default:
        return null;
    }
  }

  String _errorMessage(int status, String body) {
    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      final err = map['error'] as Map<String, dynamic>?;
      if (err != null) {
        final code = err['code'] as String? ?? 'error';
        if (code == 'rate_limited') return 'Slow down — too many requests.';
        return err['message'] as String? ?? 'Request failed ($status).';
      }
    } catch (_) {
      // fall through
    }
    return 'Request failed ($status).';
  }
}

/// Accumulates decoded text and yields complete SSE frames (separated by "\n\n").
class _SseFrameSplitter {
  String _buffer = '';

  List<String> push(String chunk) {
    _buffer += chunk;
    final frames = <String>[];
    int idx;
    while ((idx = _buffer.indexOf('\n\n')) != -1) {
      final frame = _buffer.substring(0, idx);
      _buffer = _buffer.substring(idx + 2);
      if (frame.trim().isNotEmpty) frames.add(frame);
    }
    return frames;
  }

  List<String> flush() {
    if (_buffer.trim().isEmpty) return const [];
    final frame = _buffer;
    _buffer = '';
    return [frame];
  }
}
