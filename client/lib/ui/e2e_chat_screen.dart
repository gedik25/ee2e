import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../core/connection_status.dart';
import '../core/keys_api.dart';
import '../core/socket_client.dart';
import '../crypto/identity.dart';
import '../crypto/ratchet.dart';
import '../crypto/x3dh.dart';
import '../storage/secure_keys.dart';
import 'connection_indicator.dart';
import 'message_bubble.dart';
import 'safety_number_screen.dart';

/// Faz 3 — Uçtan Uca Şifreli Sohbet Ekranı.
///
/// Mesaj akışı:
///   Alice → Bob:
///     1. Bob'un bundle'ını sunucudan çek  (KeysApi.fetchBundle)
///     2. SPK imzasını doğrula
///     3. X3DH ile SK türet
///     4. Double Ratchet başlat (initAsSender)
///     5. Mesajı şifrele (ratchet.encrypt)
///     6. {x3dh_header, encrypted_message} → Socket.IO (message:send)
///
///   Bob → Alice (yanıt):
///     1. İlk mesajdan x3dh_header ve encrypted_message'ı çıkar
///     2. X3DH.deriveAsResponder ile SK türet
///     3. Double Ratchet başlat (initAsReceiver)
///     4. Mesajı çöz (ratchet.decrypt)
///     5. Sonraki mesajlar: mevcut ratchet state'i kullan
class E2EChatScreen extends StatefulWidget {
  const E2EChatScreen({
    super.key,
    required this.client,
    required this.serverUrl,
  });

  final SocketClient client;
  final String serverUrl;

  @override
  State<E2EChatScreen> createState() => _E2EChatScreenState();
}

class _E2EMessage {
  _E2EMessage({
    required this.id,
    required this.text,
    required this.isMine,
    required this.peerId,
    required this.timestamp,
    this.state = MessageState.sending,
    this.isEncrypted = true,
  });

  final String id;
  final String text;
  final bool isMine;
  final String peerId;
  final DateTime timestamp;
  final bool isEncrypted;
  MessageState state;
}

class _E2EChatScreenState extends State<E2EChatScreen> {
  final _peerCtrl = TextEditingController();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _store = SecureKeyStore();

  ConnectionStatus _status = ConnectionStatus.connecting;
  final List<_E2EMessage> _messages = [];
  final Set<String> _seenIncoming = {};
  final Set<String> _seenAcks = {};

  /// Aktif Double Ratchet oturumları: peerId → DoubleRatchet
  final Map<String, DoubleRatchet> _sessions = {};

  /// Peer'ların X25519 IK public key'leri (Safety Number için): peerId → bytes
  final Map<String, Uint8List> _peerIkKeys = {};

  Identity? _myIdentity;
  SignedPreKey? _mySpk;
  bool _sessionReady = false;
  String? _sessionError;
  bool _establishing = false;

  late KeysApi _keysApi;
  late StreamSubscription _statusSub;
  late StreamSubscription _msgSub;
  late StreamSubscription _ackSub;

  @override
  void initState() {
    super.initState();
    _keysApi = KeysApi(baseUrl: widget.serverUrl);
    _statusSub = widget.client.status$.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _msgSub = widget.client.messages$.listen(_onIncoming);
    _ackSub = widget.client.acks$.listen(_onAck);
    _loadMyIdentity();
  }

  Future<void> _loadMyIdentity() async {
    final id = await _store.loadIdentity();
    final spk = await _store.loadSignedPreKey();
    setState(() {
      _myIdentity = id;
      _mySpk = spk;
    });
    if (id == null || spk == null) {
      setState(() {
        _sessionError =
            'Kimlik bulunamadı. Önce "Anahtar Yönetimi" ekranından kimlik üret ve yükle.';
      });
    }
  }

  // ─── Oturum kurma ───────────────────────────────────────────────────────

  /// Alice tarafı: Bob'un bundle'ını çekip X3DH + Double Ratchet başlat.
  Future<void> _establishSession(String peerId) async {
    if (_establishing) return;
    setState(() {
      _establishing = true;
      _sessionError = null;
    });

    try {
      final myId = _myIdentity;
      if (myId == null) throw Exception('Kimlik yüklenmedi');

      _log('🔑 $peerId bundle\'ı sunucudan çekiliyor...');

      final bundle = await _keysApi.fetchBundle(peerId);
      if (bundle == null) {
        throw Exception('$peerId sunucuda bulunamadı (404). Karşı taraf kimliğini yüklemeli.');
      }

      _log('✅ Bundle alındı — SPK imzası doğrulanıyor...');
      final spkOk = await bundle.verifySpkSignature();
      if (!spkOk) {
        throw Exception('❌ SPK imzası GEÇERSİZ — MITM saldırısı olabilir!');
      }

      _log('✅ İmza doğrulandı — X3DH Handshake başlatılıyor...');
      final x3dhResult = await X3DH.deriveAsInitiator(
        identity: myId,
        bobBundle: bundle,
      );

      _log('✅ X3DH SK türetildi — Double Ratchet başlatılıyor...');
      final ratchet = await DoubleRatchet.initAsSender(
        sk: x3dhResult.sk,
        bobSpkPublic: bundle.signedPreKey,
      );

      _sessions[peerId] = ratchet;
      _peerIkKeys[peerId] = bundle.identityDhKey;

      // X3DH header'ı peer ID ile ilişkilendir (ilk mesajda gönderilecek)
      _pendingX3DHHeader[peerId] = x3dhResult.header;

      setState(() {
        _sessionReady = true;
        _establishing = false;
      });
      _log('🔐 E2EE Oturum hazır! Mesajlarınız uçtan uca şifrelenecek.');
    } catch (e) {
      setState(() {
        _sessionError = e.toString();
        _establishing = false;
      });
      _log('HATA: $e');
    }
  }

  /// X3DH header'ları — ilk mesajla birlikte gönderilir, sonra temizlenir.
  final Map<String, X3DHHeader> _pendingX3DHHeader = {};

  // ─── Mesaj gönderme ─────────────────────────────────────────────────────

  Future<void> _send() async {
    final peer = _peerCtrl.text.trim();
    final text = _inputCtrl.text.trim();
    if (peer.isEmpty || text.isEmpty || _status != ConnectionStatus.online) return;

    // Oturum yoksa önce kur
    if (!_sessions.containsKey(peer)) {
      await _establishSession(peer);
      if (!_sessions.containsKey(peer)) return; // kurulum başarısız
    }

    final ratchet = _sessions[peer]!;
    final tempId = 'local-${DateTime.now().microsecondsSinceEpoch}';

    setState(() {
      _messages.add(_E2EMessage(
        id: tempId,
        text: text,
        isMine: true,
        peerId: peer,
        timestamp: DateTime.now(),
      ));
    });
    _inputCtrl.clear();
    _scrollToBottom();

    try {
      // Associated Data: sender_id || recipient_id (her iki taraf da aynı hesaplar)
      final ad = Uint8List.fromList(
        utf8.encode('${widget.client.clientId}:$peer'),
      );

      // Şifrele
      final encrypted = await ratchet.encrypt(plaintext: text, associatedData: ad);
      final encJson = encrypted.toJson();

      // İlk mesajda X3DH header'ı da ekle
      Map<String, dynamic> envelope = {
        'ee2e': true,
        'v': 1,
        'enc': encJson,
      };
      if (_pendingX3DHHeader.containsKey(peer)) {
        envelope['x3dh'] = _pendingX3DHHeader.remove(peer)!.toJson();
      }

      widget.client.sendMessage(
        recipientId: peer,
        envelope: envelope,
        clientMsgId: tempId,
      );
    } catch (e) {
      final i = _messages.indexWhere((m) => m.id == tempId);
      if (i != -1) setState(() => _messages[i].state = MessageState.failed);
      _showSnack('Şifreleme hatası: $e');
    }
  }

  // ─── Mesaj alma ──────────────────────────────────────────────────────────

  Future<void> _onIncoming(IncomingMessage incoming) async {
    if (incoming.msgId.isNotEmpty && !_seenIncoming.add(incoming.msgId)) return;

    final envelope = incoming.envelope;
    final senderId = incoming.senderId;

    // E2EE mesaj değil mi? Düz mesaj olarak göster
    if (envelope['ee2e'] != true) {
      _addIncomingMessage(incoming.msgId, senderId, '⚠️ [Şifresiz mesaj]: ${envelope['body']}');
      widget.client.acknowledgeDelivery(msgId: incoming.msgId, senderId: senderId);
      return;
    }

    try {
      // Bob tarafı: oturum henüz yok → X3DH header'dan başlat
      if (!_sessions.containsKey(senderId)) {
        final x3dhJson = envelope['x3dh'];
        if (x3dhJson == null) {
          throw Exception('İlk E2EE mesajda X3DH header eksik');
        }

        final header = X3DHHeader.fromJson(Map<String, dynamic>.from(x3dhJson as Map));
        final myId = _myIdentity;
        final mySpk = _mySpk;
        if (myId == null || mySpk == null) throw Exception('Kimlik yüklenmedi');

        // OPK tüket (header'da belirtilen id)
        OneTimePreKey? opk;
        if (header.recipientOpkId != null) {
          opk = await _store.consumeOneTimePreKey(header.recipientOpkId!);
        }

        _log('📩 $senderId\'den X3DH header alındı — SK türetiliyor...');
        final sk = await X3DH.deriveAsResponder(
          identity: myId,
          spk: mySpk,
          opk: opk,
          header: header,
        );

        _log('✅ X3DH SK türetildi — Double Ratchet (receiver) başlatılıyor...');
        final ratchet = await DoubleRatchet.initAsReceiver(sk: sk, spk: mySpk.keyPair);
        _sessions[senderId] = ratchet;

        // Sender'ın IK'sını sakla (Safety Number için)
        _peerIkKeys[senderId] = header.senderIkPublic;
      }

      // Şifreli mesajı çöz
      final encJson = Map<String, dynamic>.from(envelope['enc'] as Map);
      final encMsg = EncryptedMessage.fromJson(encJson);
      final ratchet = _sessions[senderId]!;

      final ad = Uint8List.fromList(utf8.encode('$senderId:${widget.client.clientId}'));
      final plaintext = await ratchet.decrypt(msg: encMsg, associatedData: ad);

      _addIncomingMessage(incoming.msgId, senderId, plaintext);
      widget.client.acknowledgeDelivery(msgId: incoming.msgId, senderId: senderId);
    } catch (e) {
      _addIncomingMessage(incoming.msgId, senderId, '❌ [Çözme hatası: $e]');
      debugPrint('[E2EChatScreen] decrypt error: $e');
    }
  }

  void _addIncomingMessage(String id, String senderId, String text) {
    setState(() {
      _messages.add(_E2EMessage(
        id: id,
        text: text,
        isMine: false,
        peerId: senderId,
        timestamp: DateTime.now(),
        state: MessageState.delivered,
      ));
    });
    _scrollToBottom();
  }

  void _onAck(MessageAck ack) {
    int idx = -1;
    if (ack.kind == AckKind.queued && ack.clientMsgId != null) {
      idx = _messages.indexWhere((m) => m.id == ack.clientMsgId);
      if (idx != -1) {
        final key = '${ack.kind.name}:${ack.msgId}';
        _seenAcks.add(key);
        setState(() {
          _messages[idx] = _E2EMessage(
            id: ack.msgId,
            text: _messages[idx].text,
            isMine: _messages[idx].isMine,
            peerId: _messages[idx].peerId,
            timestamp: _messages[idx].timestamp,
            state: MessageState.sent,
          );
        });
        return;
      }
    }
    final ackKey = '${ack.kind.name}:${ack.msgId}';
    if (!_seenAcks.add(ackKey)) return;
    idx = _messages.indexWhere((m) => m.id == ack.msgId);
    if (idx == -1) return;
    setState(() {
      _messages[idx].state =
          ack.kind == AckKind.delivered ? MessageState.delivered : MessageState.sent;
    });
  }

  // ─── UI yardımcıları ─────────────────────────────────────────────────────

  final List<String> _debugLog = [];

  void _log(String msg) {
    debugPrint('[E2E] $msg');
    setState(() => _debugLog.add(msg));
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
    _keysApi.close();
    _peerCtrl.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peer = _peerCtrl.text.trim();
    final hasPeer = peer.isNotEmpty;
    final hasSession = _sessions.containsKey(peer);
    final myId = _myIdentity;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.lock, size: 16),
                const SizedBox(width: 4),
                Text('E2EE — Ben: ${widget.client.clientId}',
                    style: const TextStyle(fontSize: 13)),
              ],
            ),
            ConnectionIndicator(status: _status),
          ],
        ),
        actions: [
          // Safety Number butonu
          if (hasSession && _peerIkKeys.containsKey(peer) && myId != null)
            IconButton(
              tooltip: 'Güvenlik Numarası',
              icon: const Icon(Icons.security),
              onPressed: () async {
                final myIk = await myId.dhPublicBytes();
                if (!mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SafetyNumberScreen(
                      myIdentityKey: myIk,
                      peerIdentityKey: _peerIkKeys[peer]!,
                      myHandle: myId.handle,
                      peerHandle: peer,
                    ),
                  ),
                );
              },
            ),
          // Log paneli
          IconButton(
            tooltip: 'Kripto Log',
            icon: const Icon(Icons.terminal),
            onPressed: () => _showLogSheet(context),
          ),
        ],
      ),
      body: myId == null
          ? _buildNoIdentityWarning()
          : Column(
              children: [
                // Peer ID girişi + oturum durumu
                _buildPeerBar(scheme, hasSession),

                // Hata mesajı
                if (_sessionError != null)
                  _buildErrorBanner(_sessionError!),

                // Oturum bilgisi
                if (hasSession)
                  _buildSessionBanner(scheme, peer),

                // Mesajlar
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

                // Mesaj giriş alanı
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
                            enabled: _status == ConnectionStatus.online,
                            onSubmitted: (_) => _send(),
                            decoration: InputDecoration(
                              hintText: hasSession
                                  ? '🔐 Şifreli mesaj yaz…'
                                  : 'Peer ID gir, bağlan ve yaz…',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              prefixIcon: hasSession
                                  ? const Icon(Icons.lock, size: 18)
                                  : const Icon(Icons.lock_open, size: 18),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _establishing
                            ? const SizedBox(
                                width: 40,
                                height: 40,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : IconButton.filled(
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

  Widget _buildPeerBar(ColorScheme scheme, bool hasSession) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _peerCtrl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Karşı tarafın Client ID / Handle',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: hasSession
                    ? const Icon(Icons.verified, color: Colors.green)
                    : null,
              ),
            ),
          ),
          if (!hasSession && _peerCtrl.text.trim().isNotEmpty) ...[
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _establishing ? null : () => _establishSession(_peerCtrl.text.trim()),
              icon: const Icon(Icons.handshake, size: 16),
              label: const Text('Bağlan'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSessionBanner(ColorScheme scheme, String peer) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock, size: 14, color: Colors.green),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'E2EE aktif — AES-256-GCM + Double Ratchet',
              style: const TextStyle(fontSize: 12, color: Colors.green),
            ),
          ),
          if (_peerIkKeys.containsKey(peer))
            GestureDetector(
              onTap: () async {
                final myId = _myIdentity;
                if (myId == null) return;
                final myIk = await myId.dhPublicBytes();
                if (!mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SafetyNumberScreen(
                      myIdentityKey: myIk,
                      peerIdentityKey: _peerIkKeys[peer]!,
                      myHandle: myId.handle,
                      peerHandle: peer,
                    ),
                  ),
                );
              },
              child: const Text(
                'Doğrula →',
                style: TextStyle(fontSize: 11, color: Colors.green, decoration: TextDecoration.underline),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String error) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(error, style: const TextStyle(color: Colors.red, fontSize: 12)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _sessionError = null),
          ),
        ],
      ),
    );
  }

  Widget _buildNoIdentityWarning() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_encryption_outlined, size: 64, color: Colors.orange),
            const SizedBox(height: 16),
            const Text(
              'Kimlik Bulunamadı',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'E2EE mesajlaşma için önce "Faz 2A — Anahtar Yönetimi" ekranından '
              'kimliğini üret ve sunucuya yükle.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Geri Dön'),
            ),
          ],
        ),
      ),
    );
  }

  void _showLogSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (_, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.terminal),
                  const SizedBox(width: 8),
                  const Text('Kripto İşlem Logu', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                padding: const EdgeInsets.all(12),
                itemCount: _debugLog.length,
                itemBuilder: (_, i) => Text(
                  _debugLog[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
