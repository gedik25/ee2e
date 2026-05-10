import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as IO;

import 'connection_status.dart';

/// EE2E Socket.IO istemcisi.
///
/// Faz 1: plaintext payload taşıyabilir. Faz 3'ten itibaren `envelope` her
/// zaman opaque ciphertext'tir; bu sınıf içerik hakkında HİÇBİR varsayım yapmaz
/// — sadece taşır.
class SocketClient {
  SocketClient({required this.serverUrl, required this.clientId});

  final String serverUrl;
  final String clientId;

  IO.Socket? _socket;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _messageController = StreamController<IncomingMessage>.broadcast();
  final _ackController = StreamController<MessageAck>.broadcast();

  Stream<ConnectionStatus> get status$ => _statusController.stream;
  Stream<IncomingMessage> get messages$ => _messageController.stream;
  Stream<MessageAck> get acks$ => _ackController.stream;

  ConnectionStatus _status = ConnectionStatus.offline;
  ConnectionStatus get status => _status;

  void _setStatus(ConnectionStatus s) {
    _status = s;
    _statusController.add(s);
  }

  void connect() {
    if (_socket != null) return;

    _setStatus(ConnectionStatus.connecting);

    final socket = IO.io(
      serverUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setAuth({'client_id': clientId})
          .setReconnectionAttempts(10)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(8000)
          .build(),
    );

    socket
      ..onConnect((_) => _setStatus(ConnectionStatus.online))
      ..onDisconnect((_) => _setStatus(ConnectionStatus.offline))
      ..onConnectError((_) => _setStatus(ConnectionStatus.failed))
      ..onReconnectAttempt((_) => _setStatus(ConnectionStatus.reconnecting))
      ..onReconnectFailed((_) => _setStatus(ConnectionStatus.failed))
      ..on('message:recv', (data) {
        if (data is Map) {
          _messageController.add(IncomingMessage.fromJson(
            Map<String, dynamic>.from(data),
          ));
        }
      })
      ..on('message:queued', (data) {
        if (data is Map && data['msg_id'] is String) {
          _ackController.add(MessageAck(
            msgId: data['msg_id'] as String,
            kind: AckKind.queued,
          ));
        }
      })
      ..on('message:ack', (data) {
        if (data is Map && data['msg_id'] is String) {
          _ackController.add(MessageAck(
            msgId: data['msg_id'] as String,
            kind: AckKind.delivered,
          ));
        }
      });

    socket.connect();
    _socket = socket;
  }

  void sendMessage({
    required String recipientId,
    required Map<String, dynamic> envelope,
  }) {
    final s = _socket;
    if (s == null || !s.connected) {
      throw StateError('Socket not connected');
    }
    s.emit('message:send', {
      'sender_id': clientId,
      'recipient_id': recipientId,
      'envelope': envelope,
    });
  }

  void acknowledgeDelivery({required String msgId, required String senderId}) {
    final s = _socket;
    if (s == null || !s.connected) return;
    s.emit('message:delivered', {
      'msg_id': msgId,
      'sender_id': senderId,
    });
  }

  Future<void> dispose() async {
    _socket?.dispose();
    _socket = null;
    _setStatus(ConnectionStatus.offline);
    await _statusController.close();
    await _messageController.close();
    await _ackController.close();
  }
}

class IncomingMessage {
  IncomingMessage({
    required this.msgId,
    required this.senderId,
    required this.envelope,
  });

  final String msgId;
  final String senderId;
  final Map<String, dynamic> envelope;

  factory IncomingMessage.fromJson(Map<String, dynamic> json) {
    return IncomingMessage(
      msgId: json['msg_id'] as String? ?? '',
      senderId: json['sender_id'] as String? ?? '',
      envelope: Map<String, dynamic>.from(json['envelope'] as Map? ?? {}),
    );
  }
}

enum AckKind { queued, delivered }

class MessageAck {
  MessageAck({required this.msgId, required this.kind});
  final String msgId;
  final AckKind kind;
}
