# EE2E — Yapılanlar

> Bu belge **tamamlanmış işleri** özetler. Ayrıntılı faz tablosu ve checkbox’lar için `PHASES.md`; güncel mimari için `SISTEM-MIMARISI.md` kullanılır.  
> **Son güncelleme:** Tüm fazlar (Faz 0 - Faz 5) başarıyla tamamlandıktan sonra.

---

## Özet tablo

| Faz | Ad | Durum |
|-----|-----|--------|
| 0 | Hazırlık & Mimari Dokümantasyonu | ✅ Tamamlandı |
| 1 | Altyapı + Dockerize Backend + iletim doğrulaması | ✅ Tamamlandı |
| 2A | Key Bundle Infrastructure | ✅ Tamamlandı |
| 2B | X3DH Handshake | ✅ Tamamlandı |
| 3 | 1:1 E2EE Mesajlaşma (Double Ratchet) | ✅ Tamamlandı |
| 4 | Grup Mesajlaşması & Metadata Gizliliği (Hardening) | ✅ Tamamlandı |
| 5 | MLS (TreeKEM) + Platform Optimizasyonları | ✅ Tamamlandı |

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

## Faz 2B — X3DH Handshake

**Amaç:** İki tarafın (başlatıcı ve yanıtlayıcı) birbirinden bağımsız olarak aynı `SK` (Shared Secret) değerini türetmesi; MITM'e karşı Safety Number / fingerprint doğrulaması.

### Kripto (istemci)
- `lib/crypto/x3dh.dart` — `deriveAsInitiator()` ve `deriveAsResponder()` (HKDF-SHA-256 ile `SK` türetimi).
- `lib/crypto/x3dh_header.dart` — initial message header yapısı (wire format).
- Birim testler: `SK_alice == SK_bob` doğrulaması, SPK-only fallback ve imza doğrulama testleri.
- `lib/ui/safety_number_screen.dart` — 60 haneli ondalık fingerprint görüntüleme ve doğrulama akışı.

---

## Faz 3 — 1:1 E2EE Mesajlaşma (Double Ratchet)

**Amaç:** İletilen mesajların Double Ratchet ile per-message anahtar rotasyonu yapılarak şifrelenmesi.

### Kripto (istemci)
- `lib/crypto/double_ratchet.dart` — Root, Sender ve Receiver KDF zincirleri. State yönetimi ve skipped keys cache.
- `lib/crypto/session.dart` — X3DH ile Double Ratchet'in bağlanması.
- UI Entegrasyonu: `ChatScreen` üzerinde gerçek şifreli sohbet.

---

## Faz 4 — Grup Mesajlaşması & Metadata Gizliliği (Hardening)

**Amaç:** Grup sohbetleri için Sender Keys altyapısının kurulması, mesaj boyutu gizleme ve gönderici kimliği gizliliği.

### Kripto (istemci)
- `lib/crypto/sender_key.dart` — Sender Key durum yönetimi, dağıtımı ve grup şifreleme/çözme.
- `lib/crypto/group_session.dart` — Grup oturumları yönetimi.
- `lib/crypto/padding.dart` — PKCS7 benzeri padding (512 byte bloklarına yuvarlama).
- `lib/crypto/sealed_sender.dart` — Sealed Sender mühürleme/çözme ile gönderici kimliğini gizleme.
- UI: `GroupChatScreen` ile arayüz desteği.

---

## Faz 5 — MLS (TreeKEM) + Platform Optimizasyonları

**Amaç:** MLS standardı benzeri ağaç-tabanlı anahtar yönetimi ile grup şifrelemesini ölçeklenebilir kılmak, multi-device ve push bildirim desteği.

### Kripto (istemci)
- `lib/crypto/tree_kem.dart` — TreeKEM binary tree yapısı: üye ekleme, silme, path secret türetme ve parent hash güncellemeleri.
- `lib/crypto/multi_device.dart` — Cihaz oturum yönetimi (`MultiDeviceManager`).
- **Push Bildirimleri:** Sunucu tarafında `server/app/push.py` ve istemci tarafında `lib/core/push_service.dart` üzerinden MVP/Stub altyapısı.
- **Platform Desteği:** Windows platformu için Flutter platform dosyaları eklendi (`client/windows/`).
