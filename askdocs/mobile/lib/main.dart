import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

void main() => runApp(const AskDocsApp());

class AskDocsApp extends StatelessWidget {
  const AskDocsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AskDocs',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF38BDF8),
          brightness: Brightness.dark,
        ),
      ),
      home: ChatScreen(api: HttpAskDocsApi()),
    );
  }
}

/// A single rendered chat bubble.
class ChatMessage {
  ChatMessage.user(this.text)
      : role = 'user',
        citations = const [],
        messageId = null,
        needsHandoff = false,
        ungrounded = false,
        streaming = false;

  ChatMessage.assistant()
      : role = 'assistant',
        text = '',
        citations = const [],
        messageId = null,
        needsHandoff = false,
        ungrounded = false,
        streaming = true;

  final String role;
  String text;
  List<Citation> citations;
  int? messageId;
  bool needsHandoff;
  bool ungrounded;
  bool streaming;

  bool get isUser => role == 'user';
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.api, String? userId})
      : _userId = userId;

  final AskDocsApi api;
  final String? _userId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  late final String _userId;
  String _sessionId = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _userId =
        widget._userId ?? 'flutter-${DateTime.now().microsecondsSinceEpoch}';
    _messages.add(_systemNote(
        'Ask about the uploaded documents — answers cite sources.'));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ChatMessage _systemNote(String text) {
    final m = ChatMessage.assistant();
    m.text = text;
    m.streaming = false;
    return m;
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final question = _input.text.trim();
    if (question.isEmpty || _busy) return;
    setState(() {
      _messages.add(ChatMessage.user(question));
      _messages.add(ChatMessage.assistant());
      _busy = true;
      _input.clear();
    });
    _scrollToEnd();

    final assistant = _messages.last;
    try {
      await for (final event in widget.api.streamChat(
        question: question,
        sessionId: _sessionId,
        userId: _userId,
      )) {
        if (!mounted) return;
        setState(() => _apply(event, assistant));
        _scrollToEnd();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _apply(StreamEvent event, ChatMessage assistant) {
    switch (event) {
      case SessionEvent(:final sessionId):
        _sessionId = sessionId;
      case TokenEvent(:final text):
        assistant.text += text;
      case CitationsEvent(:final citations):
        if (citations.isNotEmpty) assistant.citations = citations;
      case DoneEvent(
          :final messageId,
          :final needsHandoff,
          :final ungrounded,
          :final citations
        ):
        assistant
          ..messageId = messageId
          ..needsHandoff = needsHandoff
          ..ungrounded = ungrounded
          ..streaming = false;
        if (citations.isNotEmpty) assistant.citations = citations;
      case HandoffEvent(:final jobId):
        if (jobId != null) {
          _messages.add(
              _systemNote('A human agent has been notified (ticket #$jobId).'));
        }
      case ErrorEvent(:final message):
        assistant
          ..text = message
          ..streaming = false;
    }
  }

  Future<void> _feedback(ChatMessage m, String rating) async {
    if (m.messageId == null) return;
    try {
      await widget.api.sendFeedback(
          messageId: m.messageId!, rating: rating, userId: _userId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not record feedback.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AskDocs'),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              _messages
                ..clear()
                ..add(_systemNote(
                    'New conversation. Ask a question about your documents.'));
              _sessionId = '';
            }),
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New conversation',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, index) => _Bubble(
                message: _messages[index],
                onFeedback: _feedback,
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          _Composer(controller: _input, onSend: _send, enabled: !_busy),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.onFeedback});

  final ChatMessage message;
  final void Function(ChatMessage, String) onFeedback;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 460),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              message.text.isEmpty && message.streaming ? '…' : message.text,
              style: TextStyle(
                  color:
                      isUser ? Theme.of(context).colorScheme.onPrimary : null),
            ),
            if (message.citations.isNotEmpty)
              _CitationChips(citations: message.citations),
            if (message.ungrounded)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('⚠ Not grounded in your documents',
                    style: TextStyle(color: Colors.amber, fontSize: 12)),
              ),
            if (!isUser && message.messageId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.thumb_up_alt_outlined, size: 18),
                      onPressed: () => onFeedback(message, 'helpful'),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.thumb_down_alt_outlined, size: 18),
                      onPressed: () => onFeedback(message, 'not_helpful'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CitationChips extends StatelessWidget {
  const _CitationChips({required this.citations});

  final List<Citation> citations;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in citations)
            Chip(
              label: Text(c.label, style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer(
      {required this.controller, required this.onSend, required this.enabled});

  final TextEditingController controller;
  final VoidCallback onSend;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Ask a question…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
