import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'codec.dart';
import 'identity.dart';

/// X3DH (Extended Triple Diffie-Hellman) Handshake implementasyonu.
///
/// Signal Protokolü spesifikasyonuna göre:
///   https://signal.org/docs/specifications/x3dh/
///
/// Alice (başlatıcı): Bob'un bundle'ını alır → SK türetir → X3DH header gönderir.
/// Bob  (yanıtlayıcı): Kendi private key'leriyle + Alice'in header'ıyla SK türetir.
///
/// Her iki taraf da aynı 32-byte SK'yı bağımsız hesaplar.
/// SK, Faz 3'te Double Ratchet'in başlangıç root key'i olarak kullanılır.
class X3DH {
  static final _x25519 = Cryptography.instance.x25519();
  static final _hkdf = Hkdf(
    hmac: Hmac(Sha256()),
    outputLength: 32,
  );

  /// X3DH bilgi string'i (HKDF info parametresi).
  static final _info = Uint8List.fromList('EE2E X3DH v1'.codeUnits);

  /// Alice (başlatıcı) tarafı: Bob'un bundle'ından SK ve X3DH header üretir.
  ///
  /// [identity]   : Alice'in uzun ömürlü kimlik anahtarı
  /// [bobBundle]  : Bob'un sunucudan çekilen public bundle'ı
  ///
  /// **Önemli:** Bu metod çağrılmadan önce `bobBundle.verifySpkSignature()`
  /// çağrılmış ve sonuç `true` olmalıdır.
  static Future<X3DHResult> deriveAsInitiator({
    required Identity identity,
    required FetchedBundle bobBundle,
  }) async {
    // 1. Ephemeral key pair (EK_A) üret
    final ekPair = await _x25519.newKeyPair();
    final ekPub = await ekPair.extractPublicKey();

    // 2. Bob'un public key'lerini SimplePublicKey'e dönüştür
    final bobIK = SimplePublicKey(bobBundle.identityDhKey, type: KeyPairType.x25519);
    final bobSPK = SimplePublicKey(bobBundle.signedPreKey, type: KeyPairType.x25519);

    // 3. DH hesaplamaları (Signal X3DH spec §3.3)
    //   DH1 = DH(IK_A, SPK_B)
    //   DH2 = DH(EK_A, IK_B)
    //   DH3 = DH(EK_A, SPK_B)
    //   DH4 = DH(EK_A, OPK_B)  ← OPK varsa
    final dh1 = await _dh(identity.dhKeyPair, bobSPK);
    final dh2 = await _dh(ekPair, bobIK);
    final dh3 = await _dh(ekPair, bobSPK);

    Uint8List? dh4;
    int? usedOpkId;
    if (bobBundle.oneTimePreKey != null) {
      final bobOPK = SimplePublicKey(
        bobBundle.oneTimePreKey!.publicKey,
        type: KeyPairType.x25519,
      );
      dh4 = await _dh(ekPair, bobOPK);
      usedOpkId = bobBundle.oneTimePreKey!.opkId;
    }

    // 4. HKDF ile SK türet
    final sk = await _kdf(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4);

    // 5. Alice'in public IK ve EK'ını al (Bob'a göndermek için)
    final ikPub = await identity.dhKeyPair.extractPublicKey();

    return X3DHResult(
      sk: sk,
      header: X3DHHeader(
        senderIkPublic: Uint8List.fromList(ikPub.bytes),
        senderEkPublic: Uint8List.fromList(ekPub.bytes),
        recipientSpkId: bobBundle.signedPreKeyId,
        recipientOpkId: usedOpkId,
      ),
    );
  }

  /// Bob (yanıtlayıcı) tarafı: Alice'in X3DH header'ından SK türetir.
  ///
  /// [identity]  : Bob'un kimliği
  /// [spk]       : Bob'un Signed Pre-Key (header'daki spk_id ile eşleşmeli)
  /// [opk]       : Bob'un kullanılan OPK'sı (null → SPK-only mode)
  /// [header]    : Alice'in gönderdiği X3DH header'ı
  static Future<Uint8List> deriveAsResponder({
    required Identity identity,
    required SignedPreKey spk,
    required OneTimePreKey? opk,
    required X3DHHeader header,
  }) async {
    // Alice'in public key'lerini yükle
    final aliceIK = SimplePublicKey(header.senderIkPublic, type: KeyPairType.x25519);
    final aliceEK = SimplePublicKey(header.senderEkPublic, type: KeyPairType.x25519);

    // DH hesaplamaları (Alice'inkiyle simetrik, roller değişmiş)
    //   DH1 = DH(SPK_B, IK_A)
    //   DH2 = DH(IK_B, EK_A)
    //   DH3 = DH(SPK_B, EK_A)
    //   DH4 = DH(OPK_B, EK_A) ← OPK kullanıldıysa
    final dh1 = await _dh(spk.keyPair, aliceIK);
    final dh2 = await _dh(identity.dhKeyPair, aliceEK);
    final dh3 = await _dh(spk.keyPair, aliceEK);

    Uint8List? dh4;
    if (opk != null) {
      dh4 = await _dh(opk.keyPair, aliceEK);
    }

    return _kdf(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4);
  }

  // ─── Yardımcı metodlar ───────────────────────────────────────────────────

  /// X25519 DH — shared secret'ın raw bytes'ını döndürür.
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

  /// HKDF-SHA-256 ile tüm DH çıktılarını birleştirip 32-byte SK üretir.
  ///
  /// Signal spec: salt = 0x00...00 (32 byte), ikm = DH1 || DH2 || DH3 [|| DH4]
  static Future<Uint8List> _kdf({
    required Uint8List dh1,
    required Uint8List dh2,
    required Uint8List dh3,
    Uint8List? dh4,
  }) async {
    // IKM: DH çıktılarını sırayla birleştir
    final ikmParts = [dh1, dh2, dh3, if (dh4 != null) dh4];
    final totalLen = ikmParts.fold<int>(0, (sum, b) => sum + b.length);
    final ikm = Uint8List(totalLen);
    var offset = 0;
    for (final part in ikmParts) {
      ikm.setRange(offset, offset + part.length, part);
      offset += part.length;
    }

    // Salt: 32 sıfır byte (Signal spec §3.3)
    final saltBytes = Uint8List(32);

    final derived = await _hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: saltBytes,
      info: _info,
    );
    return Uint8List.fromList(await derived.extractBytes());
  }
}

/// X3DH Handshake sonucu (Alice tarafı).
class X3DHResult {
  const X3DHResult({required this.sk, required this.header});

  /// 32-byte Shared Secret — Double Ratchet'in root key'i olacak.
  final Uint8List sk;

  /// Bob'a iletilmesi gereken header (wire formatı için [X3DHHeader.toJson]).
  final X3DHHeader header;
}

/// X3DH wire header: Alice → Bob (ilk mesajla birlikte gönderilir).
class X3DHHeader {
  const X3DHHeader({
    required this.senderIkPublic,
    required this.senderEkPublic,
    required this.recipientSpkId,
    this.recipientOpkId,
  });

  /// Alice'in IK_dh public key'i (32 byte, X25519)
  final Uint8List senderIkPublic;

  /// Alice'in tek kullanımlık EK public key'i (32 byte, X25519)
  final Uint8List senderEkPublic;

  /// Bob'un kullanılan SPK id'si
  final int recipientSpkId;

  /// Bob'un kullanılan OPK id'si (null → SPK-only mode)
  final int? recipientOpkId;

  Map<String, dynamic> toJson() => {
        'sender_ik': B64u.encode(senderIkPublic),
        'sender_ek': B64u.encode(senderEkPublic),
        'recipient_spk_id': recipientSpkId,
        if (recipientOpkId != null) 'recipient_opk_id': recipientOpkId,
      };

  factory X3DHHeader.fromJson(Map<String, dynamic> json) {
    return X3DHHeader(
      senderIkPublic: B64u.decode(json['sender_ik'] as String),
      senderEkPublic: B64u.decode(json['sender_ek'] as String),
      recipientSpkId: json['recipient_spk_id'] as int,
      recipientOpkId: json['recipient_opk_id'] as int?,
    );
  }
}
