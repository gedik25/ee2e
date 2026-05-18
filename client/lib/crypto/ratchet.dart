import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'codec.dart';

/// Double Ratchet Algoritması — Faz 3 E2EE mesajlaşma şifresi.
///
/// Signal Protokolü spesifikasyonuna göre:
///   https://signal.org/docs/specifications/doubleratchet/
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  Kısaltmalar:                                                    │
/// │  RK  = Root Key (32 byte)                                        │
/// │  CK  = Chain Key (32 byte) — send veya recv zinciri             │
/// │  MK  = Message Key (32 byte) — tek mesaj şifresi                │
/// │  DHR = DH Ratchet Key Pair (X25519)                             │
/// └─────────────────────────────────────────────────────────────────┘
///
/// Bu implementasyon:
///   - AES-256-GCM ile mesaj şifrelemesi (AEAD)
///   - HKDF-SHA-256 ile KDF zincirleri
///   - Out-of-order mesaj teslimati için skipped message key cache
///   - Maksimum 1000 atlanmış mesaj key'i (güvenlik sınırı)
class DoubleRatchet {
  static final _x25519 = Cryptography.instance.x25519();
  static final _aesGcm = AesGcm.with256bits();
  static final _hmacSha256 = Hmac.sha256();
  static final _hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 96);

  static const _maxSkip = 1000;

  // ─── State ──────────────────────────────────────────────────────────────

  /// Gönderme zinciri DH key pair'i (kendi private key'imiz)
  SimpleKeyPair _dhSend;

  /// Karşı tarafın son gördüğümüz DH public key'i
  SimplePublicKey? _dhRecv;

  /// Root Key
  Uint8List _rootKey;

  /// Gönderme Chain Key
  Uint8List? _sendChainKey;

  /// Alma Chain Key
  Uint8List? _recvChainKey;

  /// Gönderilmiş mesaj sayısı (mevcut zincirde)
  int _sendCount = 0;

  /// Alınmış mesaj sayısı (mevcut zincirde)
  int _recvCount = 0;

  /// Önceki gönderme zincirindeki mesaj sayısı
  int _prevSendCount = 0;

  /// Atlanmış mesaj key'leri: key = "dhPub:msgIdx", value = MK
  final Map<String, Uint8List> _skippedKeys = {};

  DoubleRatchet._({
    required SimpleKeyPair dhSend,
    required SimplePublicKey? dhRecv,
    required Uint8List rootKey,
    Uint8List? sendChainKey,
    Uint8List? recvChainKey,
    int sendCount = 0,
    int recvCount = 0,
    int prevSendCount = 0,
  })  : _dhSend = dhSend,
        _dhRecv = dhRecv,
        _rootKey = rootKey,
        _sendChainKey = sendChainKey,
        _recvChainKey = recvChainKey,
        _sendCount = sendCount,
        _recvCount = recvCount,
        _prevSendCount = prevSendCount;

  // ─── Fabrika metodlar ────────────────────────────────────────────────────

  /// Alice (başlatıcı) için Ratchet başlat.
  ///
  /// [sk]           : X3DH'den gelen 32-byte Shared Secret
  /// [bobSpkPublic] : Bob'un SPK public key'i (ilk DH ratchet adımı için)
  static Future<DoubleRatchet> initAsSender({
    required Uint8List sk,
    required Uint8List bobSpkPublic,
  }) async {
    // Alice yeni bir DH ratchet key pair üretir
    final dhPair = await _x25519.newKeyPair();
    final bobPub = SimplePublicKey(bobSpkPublic, type: KeyPairType.x25519);

    // İlk DH ratchet adımı: RK ve CK türet
    final dh = await _dh(dhPair, bobPub);
    final (rk, ck) = await _kdfRk(sk, dh);

    return DoubleRatchet._(
      dhSend: dhPair,
      dhRecv: bobPub,
      rootKey: rk,
      sendChainKey: ck,
    );
  }

  /// Bob (yanıtlayıcı) için Ratchet başlat.
  ///
  /// [sk]    : X3DH'den gelen 32-byte Shared Secret
  /// [spk]   : Bob'un SPK key pair'i (X3DH'de kullanılan)
  static Future<DoubleRatchet> initAsReceiver({
    required Uint8List sk,
    required SimpleKeyPair spk,
  }) async {
    // Bob başlangıçta SPK'yı DH ratchet key olarak kullanır
    return DoubleRatchet._(
      dhSend: spk,
      dhRecv: null,
      rootKey: sk,
    );
  }

  // ─── Şifreleme / Şifre Çözme ─────────────────────────────────────────────

  /// Mesajı şifrele → [EncryptedMessage] döndür.
  ///
  /// [plaintext]    : Şifrelenecek UTF-8 metin
  /// [associatedData] : Ek doğrulama verisi (ör. sender_id + recipient_id)
  Future<EncryptedMessage> encrypt({
    required String plaintext,
    Uint8List? associatedData,
  }) async {
    // Gönderme zinciri henüz yoksa Exception (initAsSender çağrılmamış)
    if (_sendChainKey == null) {
      throw StateError('Send chain not initialized. Call initAsSender first.');
    }

    // CK → yeni CK + MK
    final (newCk, mk) = _kdfCk(_sendChainKey!);
    _sendChainKey = newCk;

    // Header: DH ratchet public key + mesaj sayaçları
    final dhPub = await _dhSend.extractPublicKey();
    final header = RatchetHeader(
      dhPublic: Uint8List.fromList(dhPub.bytes),
      messageIndex: _sendCount,
      prevChainLength: _prevSendCount,
    );

    // AES-256-GCM şifreleme
    final nonce = _generateNonce(header);
    final ad = _buildAD(associatedData, header);
    final ciphertext = await _aeadEncrypt(
      key: mk,
      nonce: nonce,
      plaintext: Uint8List.fromList(utf8.encode(plaintext)),
      ad: ad,
    );

    _sendCount++;

    return EncryptedMessage(
      header: header,
      ciphertext: ciphertext,
      nonce: nonce,
    );
  }

  /// Şifreli mesajı çöz → plaintext String döndür.
  ///
  /// [msg]            : Alınan şifreli mesaj
  /// [associatedData] : Ek doğrulama verisi (sender ile aynı değer olmalı)
  Future<String> decrypt({
    required EncryptedMessage msg,
    Uint8List? associatedData,
  }) async {
    // Önce skipped key cache'e bak (out-of-order teslim)
    final mk = await _trySkippedKey(msg, associatedData);
    if (mk != null) {
      final plain = await _aeadDecrypt(
        key: mk,
        nonce: msg.nonce,
        ciphertext: msg.ciphertext,
        ad: _buildAD(associatedData, msg.header),
      );
      return utf8.decode(plain);
    }

    // Yeni DH ratchet key mı geldi?
    final headerDhPub = SimplePublicKey(msg.header.dhPublic, type: KeyPairType.x25519);
    final currentRecvPub = _dhRecv;
    final isNewRatchet = currentRecvPub == null ||
        !_pubEqual(headerDhPub.bytes, currentRecvPub.bytes);

    if (isNewRatchet) {
      // Mevcut recv zincirindeki atlanmış mesajları cache'e al
      await _skipMessageKeys(msg.header.prevChainLength);
      // DH ratchet adımı gerçekleştir
      await _dhRatchet(headerDhPub);
    }

    // Recv zincirindeki atlanmış mesajları cache'e al
    await _skipMessageKeys(msg.header.messageIndex);

    // Mevcut mesaj key'ini türet
    final (newCk, msgKey) = _kdfCk(_recvChainKey!);
    _recvChainKey = newCk;
    _recvCount++;

    final plainBytes = await _aeadDecrypt(
      key: msgKey,
      nonce: msg.nonce,
      ciphertext: msg.ciphertext,
      ad: _buildAD(associatedData, msg.header),
    );
    return utf8.decode(plainBytes);
  }

  // ─── Yardımcı metodlar ───────────────────────────────────────────────────

  /// DH Ratchet adımı: yeni DH key pair üret, RK ve CK'ları güncelle.
  Future<void> _dhRatchet(SimplePublicKey newRemotePub) async {
    _prevSendCount = _sendCount;
    _sendCount = 0;
    _recvCount = 0;
    _dhRecv = newRemotePub;

    // Bob'un yeni DH public key'i ile recv zinciri türet
    final dh1 = await _dh(_dhSend, newRemotePub);
    final (rk1, recvCk) = await _kdfRk(_rootKey, dh1);

    // Yeni gönderme key pair üret ve send zinciri türet
    final newDhSend = await _x25519.newKeyPair();
    final dh2 = await _dh(newDhSend, newRemotePub);
    final (rk2, sendCk) = await _kdfRk(rk1, dh2);

    _dhSend = newDhSend;
    _rootKey = rk2;
    _recvChainKey = recvCk;
    _sendChainKey = sendCk;
  }

  /// Verilen mesaj index'ine kadar zincirdeki mesaj key'lerini cache'e al.
  Future<void> _skipMessageKeys(int until) async {
    if (_recvChainKey == null) return;
    if (until - _recvCount > _maxSkip) {
      throw StateError('Skipped too many messages ($until - $_recvCount > $_maxSkip)');
    }
    while (_recvCount < until) {
      final (newCk, mk) = _kdfCk(_recvChainKey!);
      _recvChainKey = newCk;
      final dhKey = _dhRecv != null ? B64u.encode(_dhRecv!.bytes) : 'init';
      _skippedKeys['$dhKey:$_recvCount'] = mk;
      _recvCount++;
    }
  }

  /// Skipped key cache'de bu mesaj için key var mı?
  Future<Uint8List?> _trySkippedKey(
    EncryptedMessage msg,
    Uint8List? ad,
  ) async {
    final dhKey = B64u.encode(msg.header.dhPublic);
    final cacheKey = '$dhKey:${msg.header.messageIndex}';
    final mk = _skippedKeys.remove(cacheKey);
    if (mk == null) return null;
    // Doğrulama: AEAD decrypt başarılı olursa key geçerlidir
    try {
      await _aeadDecrypt(
        key: mk,
        nonce: msg.nonce,
        ciphertext: msg.ciphertext,
        ad: _buildAD(ad, msg.header),
      );
      return mk;
    } catch (_) {
      return null;
    }
  }

  // ─── KDF fonksiyonları ────────────────────────────────────────────────────

  /// KDF_RK: HKDF-SHA-256 ile (RK, DH_out) → (yeni RK, CK)
  static Future<(Uint8List rk, Uint8List ck)> _kdfRk(
    Uint8List rk,
    Uint8List dhOut,
  ) async {
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 64);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(dhOut),
      nonce: rk,
      info: Uint8List.fromList('EE2E RatchetRK v1'.codeUnits),
    );
    final bytes = Uint8List.fromList(await derived.extractBytes());
    return (bytes.sublist(0, 32), bytes.sublist(32, 64));
  }

  /// KDF_CK: HMAC-SHA-256 ile CK → (yeni CK, MK) — deterministik, async yok.
  static (Uint8List newCk, Uint8List mk) _kdfCk(Uint8List ck) {
    // Synchronous HMAC-SHA-256 yaklaşımı (cryptography paketi async,
    // ancak bu zincirin her adımı senkron tutulur — performans için)
    // HMAC yerine SHA-256 tabanlı basit KDF (test-compatible):
    //   newCk = HMAC-SHA-256(key=ck, data=0x02)
    //   mk    = HMAC-SHA-256(key=ck, data=0x01)
    // Bu, Signal'ın spec'indeki KDF_CK ile birebir uyumludur.
    final newCk = _hmacOne(ck, 0x02);
    final mk = _hmacOne(ck, 0x01);
    return (newCk, mk);
  }

  /// Basit tek-byte HMAC-SHA-256 (synchronous — dart:crypto üzerinden).
  static Uint8List _hmacOne(Uint8List key, int byte) {
    // Pure Dart HMAC-SHA-256 implementasyonu
    const blockSize = 64;
    final ipad = Uint8List(blockSize + 1);
    final opad = Uint8List(blockSize + 1);

    final k = key.length > blockSize ? _sha256(key) : key;
    for (var i = 0; i < blockSize; i++) {
      ipad[i] = (i < k.length ? k[i] : 0) ^ 0x36;
      opad[i] = (i < k.length ? k[i] : 0) ^ 0x5c;
    }
    ipad[blockSize] = byte;

    final inner = _sha256(ipad);
    final outerInput = Uint8List(blockSize + 32);
    outerInput.setRange(0, blockSize, opad.sublist(0, blockSize));
    outerInput.setRange(blockSize, blockSize + 32, inner);

    return _sha256(outerInput);
  }

  /// Pure Dart SHA-256 — dart:convert'ten daha önce gelen, lightweight.
  /// cryptography paketine async bağımlı olmadan çalışır.
  static Uint8List _sha256(Uint8List data) {
    // SHA-256 sabit değerleri
    final h = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    final k = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
      0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
      0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
      0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
      0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
      0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    // Padding
    final msgLen = data.length;
    final bitLen = msgLen * 8;
    final padLen = ((msgLen + 9 + 63) ~/ 64) * 64;
    final padded = Uint8List(padLen);
    padded.setRange(0, msgLen, data);
    padded[msgLen] = 0x80;
    for (var i = 0; i < 8; i++) {
      padded[padLen - 8 + i] = (bitLen >> (56 - i * 8)) & 0xff;
    }

    int rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;
    int add(int a, int b) => (a + b) & 0xffffffff;

    // Bloklara ayır ve işle
    for (var chunk = 0; chunk < padLen; chunk += 64) {
      final w = List<int>.filled(64, 0);
      for (var i = 0; i < 16; i++) {
        w[i] = (padded[chunk + i * 4] << 24) |
            (padded[chunk + i * 4 + 1] << 16) |
            (padded[chunk + i * 4 + 2] << 8) |
            padded[chunk + i * 4 + 3];
        w[i] = w[i].toUnsigned(32);
      }
      for (var i = 16; i < 64; i++) {
        final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = add(add(add(w[i - 16], s0), w[i - 7]), s1);
      }

      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];

      for (var i = 0; i < 64; i++) {
        final S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        final ch = (e & f) ^ ((~e) & g);
        final temp1 = add(add(add(add(hh, S1), ch), k[i]), w[i]);
        final S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = add(S0, maj);

        hh = g; g = f; f = e;
        e = add(d, temp1);
        d = c; c = b; b = a;
        a = add(temp1, temp2);
      }

      h[0] = add(h[0], a); h[1] = add(h[1], b);
      h[2] = add(h[2], c); h[3] = add(h[3], d);
      h[4] = add(h[4], e); h[5] = add(h[5], f);
      h[6] = add(h[6], g); h[7] = add(h[7], hh);
    }

    final digest = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      digest[i * 4] = (h[i] >> 24) & 0xff;
      digest[i * 4 + 1] = (h[i] >> 16) & 0xff;
      digest[i * 4 + 2] = (h[i] >> 8) & 0xff;
      digest[i * 4 + 3] = h[i] & 0xff;
    }
    return digest;
  }

  // ─── AEAD (AES-256-GCM) ─────────────────────────────────────────────────

  static Future<Uint8List> _aeadEncrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List ad,
  }) async {
    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: ad,
    );
    // ciphertext || tag
    final result = Uint8List(secretBox.cipherText.length + secretBox.mac.bytes.length);
    result.setRange(0, secretBox.cipherText.length, secretBox.cipherText);
    result.setRange(secretBox.cipherText.length, result.length, secretBox.mac.bytes);
    return result;
  }

  static Future<Uint8List> _aeadDecrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List ad,
  }) async {
    // Son 16 byte = GCM tag
    if (ciphertext.length < 16) throw StateError('Ciphertext too short');
    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final tag = ciphertext.sublist(ciphertext.length - 16);

    final box = SecretBox(ct, nonce: nonce, mac: Mac(tag));
    final plain = await _aesGcm.decrypt(
      box,
      secretKey: SecretKey(key),
      aad: ad,
    );
    return Uint8List.fromList(plain);
  }

  // ─── Diğer yardımcılar ───────────────────────────────────────────────────

  static Future<Uint8List> _dh(
    SimpleKeyPair localKp,
    SimplePublicKey remotePub,
  ) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: localKp,
      remotePublicKey: remotePub,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  /// Nonce: header'ın deterministik türetimi (12 byte AES-GCM nonce)
  static Uint8List _generateNonce(RatchetHeader header) {
    final n = Uint8List(12);
    // İlk 4 byte: mesaj index
    n[0] = (header.messageIndex >> 24) & 0xff;
    n[1] = (header.messageIndex >> 16) & 0xff;
    n[2] = (header.messageIndex >> 8) & 0xff;
    n[3] = header.messageIndex & 0xff;
    // Kalan 8 byte: DH public key'in ilk 8 byte'ı (çeşitlik için)
    final dhBytes = header.dhPublic;
    for (var i = 0; i < 8 && i < dhBytes.length; i++) {
      n[4 + i] = dhBytes[i];
    }
    return n;
  }

  /// Associated Data: sender_id/recipient_id + header JSON (deterministic)
  static Uint8List _buildAD(Uint8List? extra, RatchetHeader header) {
    final headerBytes = utf8.encode(jsonEncode(header.toJson()));
    if (extra == null) return Uint8List.fromList(headerBytes);
    final ad = Uint8List(extra.length + headerBytes.length);
    ad.setRange(0, extra.length, extra);
    ad.setRange(extra.length, ad.length, headerBytes);
    return ad;
  }

  /// SHA-256 public wrapper — Safety Number hesabı için dışarıdan erişilebilir.
  static Uint8List sha256Pub(Uint8List data) => _sha256(data);

  static bool _pubEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Double Ratchet mesaj başlığı.
class RatchetHeader {
  const RatchetHeader({
    required this.dhPublic,
    required this.messageIndex,
    required this.prevChainLength,
  });

  /// Gönderenin mevcut DH ratchet public key'i (32 byte, X25519)
  final Uint8List dhPublic;

  /// Bu mesajın mevcut gönderme zincirindeki index'i
  final int messageIndex;

  /// Önceki gönderme zincirindeki mesaj sayısı
  final int prevChainLength;

  Map<String, dynamic> toJson() => {
        'dh': B64u.encode(dhPublic),
        'n': messageIndex,
        'pn': prevChainLength,
      };

  factory RatchetHeader.fromJson(Map<String, dynamic> json) {
    return RatchetHeader(
      dhPublic: B64u.decode(json['dh'] as String),
      messageIndex: json['n'] as int,
      prevChainLength: json['pn'] as int,
    );
  }
}

/// Şifreli mesaj wire formatı.
class EncryptedMessage {
  const EncryptedMessage({
    required this.header,
    required this.ciphertext,
    required this.nonce,
  });

  /// Double Ratchet mesaj başlığı
  final RatchetHeader header;

  /// AES-256-GCM şifreli veri + 16-byte tag
  final Uint8List ciphertext;

  /// AES-GCM nonce (12 byte)
  final Uint8List nonce;

  Map<String, dynamic> toJson() => {
        'header': header.toJson(),
        'ct': B64u.encode(ciphertext),
        'nonce': B64u.encode(nonce),
        'v': 1, // protokol versiyonu
      };

  factory EncryptedMessage.fromJson(Map<String, dynamic> json) {
    return EncryptedMessage(
      header: RatchetHeader.fromJson(json['header'] as Map<String, dynamic>),
      ciphertext: B64u.decode(json['ct'] as String),
      nonce: B64u.decode(json['nonce'] as String),
    );
  }
}
