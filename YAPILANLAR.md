# EE2E — Yapılanlar

> Bu belge **tamamlanmış işleri** özetler. Ayrıntılı faz tablosu ve checkbox’lar için `PHASES.md`; güncel mimari için `SISTEM-MIMARISI.md` kullanılır.  
> **Son güncelleme:** Faz 0, 1, 2A, 2B ve 3 tamamlandıktan sonra.

---

## Özet tablo

| Faz | Ad | Durum |
|-----|-----|--------|
| 0 | Hazırlık & Mimari Dokümantasyonu | Tamamlandı |
| 1 | Altyapı + Dockerize Backend + iletim doğrulaması | Tamamlandı |
| 2A | Key Bundle Infrastructure | Tamamlandı |
| 2B | X3DH Handshake | Tamamlandı |
| 3 | 1:1 E2EE Mesajlaşma (Double Ratchet + AES-256-GCM) | Tamamlandı |

---

## Faz 0 — Hazırlık ve dokümantasyon

- Üç katmanlı mimari ve faz planının yazılması: `ARCHITECTURE.md`, `PHASES.md`.
- Güvenlik ilkeleri ve tehdit modeli dokümanları: `docs/security-pillars.md`, `docs/threat-model.md`, `docs/glossary.md`.
- Operasyon rehberleri: `docs/ngrok-quickstart.md`, `docs/tls-letsencrypt.md`.
- Repo yapısı: `server/` ve `client/` ayrımı, `.gitignore`, örnek ortam dosyaları.

---

## Faz 1 — Altyapı ve iletim (şifreleme öncesi)

**Amaç:** Uzak istemcilerin aynı sunucuya bağlanıp gerçek zamanlı mesaj alışverişi yapabilmesi; mesaj içeriğinin sunucuda **kalıcı olarak saklanmaması**; loglarda hassas alanların maskelenmesi.

### Sunucu

- **Docker:** `server/Dockerfile` (Python 3.12, non-root, multi-stage), `server/docker-compose.yml` (`app` + Postgres 16), Makefile komutları.
- **Uygulama:** `server/app/server.py` — Flask factory, Flask-SocketIO (eventlet), `GET /health` (DB ping + kuyruk boyutu).
- **Socket.IO:** `connect` (`auth.client_id`), `disconnect`, `room:join` / `room:leave`, `message:send` (relay + kuyruk + `client_msg_id` round-trip), `message:delivered` (ack, kuyruktan silme).
- **Ephemeral kuyruk:** `server/app/ephemeral_queue.py` — process içi, TTL (varsayılan 24 saat, üst sınır 7 gün), thread-safe.
- **Loglama:** `server/app/logging_config.py` — JSON formatter ile `body` / `plaintext` / `ciphertext` vb. redaksiyon.
- **Statik web:** Flutter `build/web` container’a mount; tek origin’den web + API + Socket.IO.

### Veritabanı (Faz 1 sonrası şema hazır)

- `server/db/schema.sql` — `users`, `key_bundles`, `one_time_prekeys` (Faz 2A’da kullanıma geçti). **Mesaj tablosu yok.**

### Güvenlik ve sertleştirme

- CORS (`CORS_ORIGINS`), `flask-limiter` (ör. 200/dk), container `read_only`, `cap_drop: ALL`, Postgres’in host’a port publish edilmemesi.
- Pytest: ephemeral kuyruk, log redaksiyonu, Socket.IO relay senaryoları (mesaj içeriği loga sızmaz).

### İstemci (Flutter)

- Bağlantı: `SocketClient`, `ConnectionStatus`, `ConnectionIndicator`.
- Sohbet: `ConnectionScreen`, `ChatScreen`, `MessageBubble` (gönderiliyor / gönderildi / iletilildi), `client_msg_id` ile sunucu `msg_id` eşlemesi.
- Platform: Android / iOS / macOS / web; macOS ağ izinleri (entitlements).

### Pratik doğrulama

- Yerel ve ngrok üzerinden iki istemci ile mesajlaşma doğrulandı (plaintext iletim).

---

## Faz 2A — Public anahtar dağıtımı

**Amaç:** Kimlik ve ön-anahtarların cihazda üretilmesi; sunucuda **yalnızca public** materyalin tutulması; OPK’nın **atomik** tüketilmesi; OPK bitince **SPK-only** fallback.

### Kripto (istemci)

- `Identity`: X25519 (DH) + Ed25519 (imza).
- `SignedPreKey`: X25519, Ed25519 ile imzalı.
- `OneTimePreKey`: 100 adet batch üretim.
- `PublicKeyBundle` / `FetchedBundle` ve SPK imza doğrulaması (`verifySpkSignature`).

### Depolama ve API

- `SecureKeyStore` — `flutter_secure_storage` ile private materyal; OPK tüketiminde yerel havuzdan silme.
- `KeysApi` — `POST /api/v1/keys/bundle`, `GET .../bundle/<handle>`, istatistik endpoint’i.

### Sunucu

- `api_keys.py`, `keys_repo.py`, `db.py` — şema doğrulama, yasak alan reddi (anahtar adında `private_`, `secret`, `_priv` alt dizgisi; bkz. `SISTEM-MIMARISI.md` §7), `FOR UPDATE SKIP LOCKED` ile OPK silme.
- Pytest: bundle yükleme, fetch ile tüketim, SPK-only, idempotent upload, 404, validation testleri.

### UI

- `IdentityScreen` — kimlik üret, bundle yükle, karşı tarafı çek, imzayı doğrula; web için “demo only” uyarısı.

---

## Bu belgenin kapsam dışı bıraktığı şeyler

- **Henüz yok:** Grup şifrelemesi, MLS, multi-device — bunlar `YAPILACAKLAR.md` içindedir.
- **Faz 1 checklist'te açık kalan maddeler:** `PHASES.md` içinde bazı DoD satırları hâlâ `[ ]` (ör. opsiyonel CI, manuel smoke notları); **faz tamamlandı** sayılsa da takip için oraya bakılabilir.

---

## Faz 2B — X3DH Handshake

**Amaç:** İki tarafın (başlatıcı ve yanıtlayıcı) birbirinden bağımsız olarak aynı `SK` (Shared Secret) değerini türetmesi; MITM'e karşı Safety Number / fingerprint doğrulaması.

### Kripto (istemci)

- `lib/crypto/x3dh.dart` — `X3DH` sınıfı:
  - `deriveAsInitiator()` — Başlatıcı tarafı: yanıtlayıcının bundle'ından EK üret, 4 DH hesapla (DH1..DH4), HKDF-SHA-256 ile 32-byte `SK` türet, `X3DHHeader` oluştur.
  - `deriveAsResponder()` — Yanıtlayıcı tarafı: başlatıcının header'ından kendi private key'leriyle simetrik DH hesapla, aynı `SK`'yı bağımsız türet.
  - `X3DHResult` — `(sk, header)` çifti: başlatıcının yanıtlayıcıya göndermesi gereken wire header ile türetilen SK.
  - `X3DHHeader` — wire format (base64url JSON): `sender_ik`, `sender_ek`, `recipient_spk_id`, `recipient_opk_id`.
  - OPK varsa DH4 dahil edilir; OPK yoksa SPK-only fallback (DH4 atlanır).
  - Salt: 32 sıfır byte; info: `"EE2E X3DH v1"` (Signal spec §3.3 uyumlu).

### UI

- `lib/ui/safety_number_screen.dart` — `SafetyNumberScreen`:
  - SHA-256(min(IK_başlatıcı, IK_yanıtlayıcı) || max(IK_başlatıcı, IK_yanıtlayıcı)) — lexicografik sıralama ile determinizm.
  - 60 haneli ondalık grup formatı (Signal standardı: 5 byte → 5 hane, boşlukla ayrılmış).
  - Doğrulama akışı: kullanıcı karşı tarafla karşılaştırır, "Doğrula" butonuna basar.
  - Kopyalama butonu ve teknik detay (SHA-256 açıklaması).

---

## Faz 3 — 1:1 E2EE Mesajlaşma

**Amaç:** Her mesaj AES-256-GCM ile şifrelenip Double Ratchet (DR) zincirleriyle anahtar rotasyonu yapılır. Sunucu hiçbir plaintext göremez.

### Kripto (istemci)

- `lib/crypto/ratchet.dart` — `DoubleRatchet` sınıfı:
  - `initAsSender(sk, recipientSpkPublic)` — Başlatıcı: ilk DH ratchet adımını gerçekleştirir, `sendChainKey` hazırlar.
  - `initAsReceiver(sk, spk)` — Yanıtlayıcı: SPK key pair ile Ratchet state'ini başlatır.
  - `encrypt(plaintext, [associatedData])` → `EncryptedMessage` — CK → yeni CK + MK; AES-256-GCM ile şifrele.
  - `decrypt(msg, [associatedData])` → `String` — skipped key cache kontrol; gerekirse DH Ratchet adımı; şifre çöz.
  - `KDF_RK`: HKDF-SHA-256 ile (RK, DH\_out) → (yeni RK, CK) — 64 byte türetilir, ikiye bölünür.
  - `KDF_CK`: HMAC-SHA-256 ile CK + `0x01`/`0x02` sabit byte → (MK, yeni CK) — Signal spec birebir.
  - HMAC-SHA-256 pure Dart ile implementasyon (async bağımlılığı yok, zincir senkron çalışır).
  - Skipped key cache: out-of-order mesaj teslimati; maksimum 1000 atlanmış key güvenlik sınürü.
  - `sha256Pub()` — Safety Number hesabı için dışarıya açık static metod.
  - `RatchetHeader` — `dh` (X25519 pub, base64url), `n` (mesaj index), `pn` (önceki zincir uzunluğu).
  - `EncryptedMessage` — `header` + `ct` (ciphertext+tag, base64url) + `nonce` (12 byte) + `v:1` (protokol versiyonu).

### UI

- `lib/ui/e2e_chat_screen.dart` — `E2EChatScreen`:
  - **Başlatıcı tarafı:** peer handle girilince `KeysApi.fetchBundle` → SPK imza doğrulama → `X3DH.deriveAsInitiator` → `DoubleRatchet.initAsSender` → ilk mesajda `x3dh` header JSON olarak envelope'a eklenir.
  - **Yanıtlayıcı tarafı:** İlk E2EE mesaj geldiğinde `x3dh` header'dan `X3DH.deriveAsResponder` → `DoubleRatchet.initAsReceiver` → şifre çözme.
  - Sonraki mesajlar: mevcut Ratchet state otomatik kullanılır, DH ratchet adımı gerektiğinde otomatik tetiklenir.
  - Bağlantı ekranında **"Faz 3 — 🔐 Şifreli Sohbet Başlat"** ana buton olarak eklendi.
  - Oturum hazır olduğunda yeşil E2EE banner gösterilir ("AES-256-GCM + Double Ratchet").
  - "Güvenlik Numarası" ikonu: AppBar'dan `SafetyNumberScreen`'e hızlı geçiş.
  - Kripto log paneli (terminal ikonu): X3DH ve Ratchet adımları gerçek zamanlı izlenebilir.
  - Kimlik yüklü değilse "Kimlik Bulunamadı" uyarı ekranı.

### Wire protokolü (Faz 3)

- Envelope formatı: `{ "ee2e": true, "v": 1, "enc": <EncryptedMessage.toJson()>, ["x3dh": <X3DHHeader.toJson()>] }`
- `x3dh` alanı yalnızca ilk mesajda bulunur; sonraki mesajlarda atlanır.
- Sunucu yalnızca opaque envelope taşır — plaintext veya şifreleme anahtarlarına asla dokunamaz.

---

*Detaylı iş kırılımı ve retrospektif: `PHASES.md`.*



client/lib/crypto/x3dh.dart (Faz 2B - X3DH)
Ne işe yarıyor: İki kişinin (Alice ve Bob) birbirleriyle internet üzerinden şifreli konuşmaya başlarken, araya kimsenin girememesi için aynı ortak gizli anahtarı (SK - Shared Secret) üretmesini sağlıyor. (Diffie-Hellman matematiği burada yapılıyor).

client/lib/crypto/ratchet.dart (Faz 3 - Double Ratchet)
Ne işe yarıyor: Mesajlaşırken her bir kelimede, her bir mesajda şifrenin sürekli değişmesini sağlıyor. Buna "Double Ratchet" deniyor. Eğer biri bugünkü şifreyi kırsa bile, dünkü mesajları çözemiyor (Forward Secrecy). Mesajı AES-256-GCM ile şifreleyen kodlar burada.

client/lib/ui/e2e_chat_screen.dart (Arayüz ve Bağlantı)
Ne işe yarıyor: Tarayıcıda gördüğün o siyah sohbet ekranı. Yazdığın mesajı alıp ratchet.dart'a gönderip şifreletiyor, sonra o şifreli anlamsız metni sunucuya (Socket.IO üzerinden) yolluyor. Karşı taraf alınca da aynı dosyada şifre çözülüp ekrana yazdırılıyor.