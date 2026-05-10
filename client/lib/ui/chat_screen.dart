import 'dart:async';

import 'package:flutter/material.dart';

import '../core/connection_status.dart';
import '../core/socket_client.dart';
import 'connection_indicator.dart';
import 'message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.client});

  final SocketClient client;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatMessage {
  _ChatMessage({
    required this.id,
    required this.text,
    required this.isMine,
    required this.peerId,
    required this.timestamp,
    this.state = MessageState.sending,
  });

  final String id;
  final String text;
  final bool isMine;
  final String peerId;
  final DateTime timestamp;
  MessageState state;
}

class _ChatScreenState extends State<ChatScreen> {
  final _peerCtrl = TextEditingController();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  ConnectionStatus _status = ConnectionStatus.connecting;
  final List<_ChatMessage> _messages = [];

  late StreamSubscription _statusSub;
  late StreamSubscription _msgSub;
  late StreamSubscription _ackSub;

  @override
  void initState() {
    super.initState();
    _statusSub = widget.client.status$.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _msgSub = widget.client.messages$.listen(_onIncoming);
    _ackSub = widget.client.acks$.listen(_onAck);
  }

  void _onIncoming(IncomingMessage incoming) {
    final body = incoming.envelope['body'];
    final text = body is String ? body : '<binary ${incoming.envelope.length}b>';
    setState(() {
      _messages.add(_ChatMessage(
        id: incoming.msgId,
        text: text,
        isMine: false,
        peerId: incoming.senderId,
        timestamp: DateTime.now(),
        state: MessageState.delivered,
      ));
    });
    widget.client.acknowledgeDelivery(
      msgId: incoming.msgId,
      senderId: incoming.senderId,
    );
    _scrollToBottom();
  }

  void _onAck(MessageAck ack) {
    final idx = _messages.indexWhere((m) => m.id == ack.msgId);
    if (idx == -1) return;
    setState(() {
      _messages[idx].state = ack.kind == AckKind.delivered
          ? MessageState.delivered
          : MessageState.sent;
    });
  }

  void _send() {
    final peer = _peerCtrl.text.trim();
    final text = _inputCtrl.text.trim();
    if (peer.isEmpty || text.isEmpty || _status != ConnectionStatus.online) return;

    final tempId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _messages.add(_ChatMessage(
        id: tempId,
        text: text,
        isMine: true,
        peerId: peer,
        timestamp: DateTime.now(),
      ));
    });

    try {
      widget.client.sendMessage(
        recipientId: peer,
        envelope: {'body': text},
      );
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        if (!mounted) return;
        final i = _messages.indexWhere((m) => m.id == tempId);
        if (i != -1) {
          setState(() => _messages[i].state = MessageState.sent);
        }
      });
    } catch (_) {
      final i = _messages.indexWhere((m) => m.id == tempId);
      if (i != -1) {
        setState(() => _messages[i].state = MessageState.failed);
      }
    }

    _inputCtrl.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _statusSub.cancel();
    _msgSub.cancel();
    _ackSub.cancel();
    widget.client.dispose();
    _peerCtrl.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Ben: ${widget.client.clientId}',
                style: const TextStyle(fontSize: 14)),
            ConnectionIndicator(status: _status),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _peerCtrl,
              decoration: const InputDecoration(
                labelText: 'Karşı tarafın Client ID',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                return MessageBubble(
                  text: m.text,
                  isMine: m.isMine,
                  state: m.state,
                  timestamp: m.timestamp,
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      minLines: 1,
                      maxLines: 4,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Mesaj yaz…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _status == ConnectionStatus.online ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
