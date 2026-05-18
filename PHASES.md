# EE2E — Faz Planı ve Durum Takibi

> **Yaşayan doküman.** Her faz sonunda checkbox'lar güncellenir, kazanılan dersler "Retrospektif" bölümüne eklenir.

| Faz | Ad                                  | Durum         | Hedef Çıktı                                              |
|-----|-------------------------------------|---------------|----------------------------------------------------------|
| 0    | Hazırlık & Mimari Dokümantasyonu  | ✅ Tamamlandı   | `ARCHITECTURE.md`, `PHASES.md`, repo iskeleti           |
| 1    | Altyapı + Dockerize Backend        | ✅ Tamamlandı   | macOS↔Chrome local + ngrok üzerinden uzak istemci ile mesajlaşma doğrulandı |
| 2A   | Key Bundle Infrastructure          | ✅ Tamamlandı   | Cihazda key üretimi + sunucuda public bundle dağıtımı + atomik OPK tüketimi |
| 2B   | X3DH Handshake                     | ✅ Tamamlandı   | Alice ↔ Bob aynı `SK` türetir; safety number / fingerprint MVP |
| 3    | 1:1 E2EE Mesajlaşma                | ✅ Tamamlandı   | Double Ratchet + AES-256-GCM, gerçek şifreli mesaj      |
| 4    | Grup + Metadata Hardening          | ⬜ Beklemede    | Sender Keys + Padding + Sealed Sender                   |
| 5    | MLS + Platform Optimizasyonları    | ⬜ Beklemede    | TreeKEM grup, push bildirim, multi-platform             |

---

## Faz 1 — Altyapı ve Bağlantı Doğrulama

> **Tek cümlelik hedef:** *"Bir arkadaşım dünyanın başka bir yerinden uygulamamı açtığında, sunucuma bağlanabilsin, kendi odasına katılsın ve bana şifresiz de olsa bir 'Merhaba' mesajını anlık olarak ulaştırabilsin."*

### Başarı Kriteri (Definition of Done)

- [ ] `docker-compose up` ile sunucu + DB tek komutla ayağa kalkıyor
- [ ] `curl https://<ngrok-url>/health` → `{"status":"ok"}` döndürüyor
- [ ] İki Flutter istemcisi (farklı IP'lerden) bağlanıp room'a katılabiliyor
- [ ] A → B'ye gönderilen plaintext mesaj < 500 ms'de B'nin ekranına düşüyor
- [ ] B çevrimdışıysa mesaj ephemeral queue'ya düşüyor; B online olunca alıyor
- [ ] B `delivered` ack gönderdikten sonra mesaj sunucudan **silinmiş** (DB'de iz yok)
- [ ] Sunucu loglarında **HİÇBİR** mesaj içeriği görünmüyor (zero-log policy)
- [ ] Flutter UI: bağlantı durumu (Online/Offline/Reconnecting) gösteriliyor
- [ ] Flutter UI: mesaj durumu (Gönderildi ✓ / İletildi ✓✓) gösteriliyor

### İş Kırılım Yapısı (Departman Bazlı)

#### 🔧 1. DevOps / Sistem Mühendisliği

- [x] `server/Dockerfile` — Python 3.12-slim base, non-root user, multi-stage build
- [x] `server/docker-compose.yml` — `app` + `db` (postgres:16-alpine) servisleri
- [x] `.env.example` — `POSTGRES_PASSWORD`, `FLASK_SECRET`, `LOG_LEVEL`
- [x] `.gitignore` — `.env`, `*.pem`, `__pycache__/`, `.dart_tool/`, `build/`
- [x] `server/Makefile` — `make up`, `make down`, `make logs`, `make shell`, `make test-no-leak`
- [x] Healthcheck: docker-compose `healthcheck` direktifi (DB ready'ye kadar app beklesin)
- [x] Ngrok recipe — `docs/ngrok-quickstart.md`
- [ ] (Opsiyonel) GitHub Actions — `docker build` smoke test

#### 🧠 2. Backend / Yazılım Mühendisliği

- [x] `server/app/server.py` — Flask + Flask-SocketIO factory pattern
- [x] `GET /health` — DB ping dahil
- [x] Socket events:
  - [x] `connect` — `auth.client_id` ile basit auth (Faz 1)
  - [x] `disconnect` — log
  - [x] `room:join` — `room=user_id`'a katıl
  - [x] `message:send` — payload'ı recipient'in room'una emit et + offline queue
  - [x] `message:delivered` — ephemeral queue'dan kaydı sil
- [x] `server/db/schema.sql` — `users`, `key_bundles`, `one_time_prekeys` tabloları (Faz 2'ye hazır boş şema)
- [x] `server/app/ephemeral_queue.py` — in-memory dict + TTL (Faz 3'te Redis'e taşınacak)
- [x] Yapılandırılmış JSON logging — `body/ciphertext/plaintext/payload` otomatik `<redacted>`
- [ ] **Smoke test:** `make up && curl localhost:5000/health` → `{"status":"ok",...}` (Docker'lı bir ortamda manuel doğrulama bekliyor)

#### 🛡️ 3. Güvenlik Mühendisliği

- [x] TLS: ngrok otomatik HTTPS sağlar; production için `docs/tls-letsencrypt.md` (Nginx + certbot stack)
- [x] CORS politikası — `CORS_ORIGINS` env-var ile kontrol
- [x] Rate-limit: `flask-limiter` ile default 200/min
- [x] Container hardening: non-root user (uid 1001), `read_only`, `cap_drop: [ALL]`, `no-new-privileges`
- [x] Postgres dış porta açılmaz (`expose:` kullan, `ports:` değil)
- [x] Zero-log policy doğrulama: `SafeJSONFormatter` + pytest canary test + `make test-no-leak`
- [x] `docs/security-pillars.md` — 4 sütun için faz-faz uygulama

#### 🎨 4. Tasarım / UX

- [x] `client/` — manuel scaffold (`pubspec.yaml` + `lib/`); `flutter create` ile platform klasörleri eklenecek
- [x] Bağlantı durumu widget'ı: 🟢 Online / 🟡 Reconnecting / 🔴 Offline / ❌ Failed (`ConnectionIndicator`)
- [x] Basit chat UI: peer ID input + mesaj listesi + gönder butonu (`ChatScreen`)
- [x] Mesaj durumu: ⏱ Gönderiliyor → ✓ Gönderildi → ✓✓ İletildi (`MessageBubble`)
- [x] Tema: light/dark (Material 3 + system theme)
- [x] Responsive: `ConstrainedBox(maxWidth: 480)` ile desktop'ta da düzgün
- [ ] **Manuel doğrulama:** `cd client && flutter create .` (platform klasörleri için) → `flutter run`

### Faz 1 Riskleri

| Risk                                      | Olasılık | Etki   | Azaltım                                     |
|-------------------------------------------|----------|--------|---------------------------------------------|
| Ngrok ücretsiz tier kararsız              | Orta     | Düşük  | Cloudflare Tunnel veya küçük VPS hazırda    |
| Flutter SocketIO client TLS sorunları     | Düşük    | Orta   | `socket_io_client` paketi + cert validation |
| In-memory queue restart'ta veri kaybı     | Yüksek   | Düşük  | Faz 1 zaten "best-effort" — kabul edilebilir|
| Mesaj loglara sızar                       | Orta     | Yüksek | Custom logging filter + smoke test          |

### Retrospektif

**Ne iyi gitti:**
- 3 katmanlı mimari (istemci / iletişim / sunucu) baştan net çizildi → bug fix'ler hep doğru katmanda kaldı.
- Zero-log policy başından beri SafeJSONFormatter ile zorunlandı; ngrok üzerinden gerçek mesajlar geçti, loglar temiz.
- Pytest entegrasyon testleri (20/20) gerçek hatayı bulduğu yer oldu: client_msg_id eşleşmemesi, sandbox engeli vs. test öncesi kod review'da fark edilmemişti.

**Ne kötü gitti:**
- macOS Sandbox `network.client` izni atlanmıştı → "Bağlantı başarısız" → debug kayboldu, 1 saat kaybı.
- 5000 portu (AirPlay Receiver) çakışması → 5050'ye taşımak gerekti.
- Dockerfile `pip install --user` ile builder→runtime kopyalama yapıyordu ama appuser HOME farklıydı → `ModuleNotFoundError`. `PYTHONUSERBASE` ile çözüldü.
- Flutter web ngrok'tan ayrı serve edilmek istendi ama tek tünel daha pratik çıktı → backend Flutter web'i de servis ediyor.
- Sender'ın local-id'si server'ın UUID'si ile eşleşmiyordu → ✓✓ animasyonu çalışmıyordu. `client_msg_id` round-trip ile çözüldü.

**Faz 2'ye taşınacak teknik borç:**
- Auth: `client_id` query param ile basit auth — Faz 2'de IK signature ile değiştirilmeli.
- Ephemeral queue: in-memory, restart'ta veri kaybı. Faz 3'te Redis.
- Multi-tab dedup: Aynı kullanıcı iki sekmede açarsa room broadcast iki cihaza da gider — Faz 3 multi-device tasarımıyla beraber netleşecek.
- Web build production-grade değil: `flutter build web --release` kullanılıyor ama service worker yok, asset cache stratejisi yok.
- Reconnect logic agresif: `_disposed` guard eklendi ama race condition'lar tam test edilmedi.

---

## Faz 2 — Identity & Key Management

> Faz 2 iki alt faza bölündü. **2A** "anahtar dağıtım altyapısı"nı, **2B** "X3DH handshake"i kurar. Bu sayede kripto kodu tek başına izole test edilebilir, bug'lar dağılmaz.

### Kripto Kararları (Sabitlenmiş)

| Karar | Değer | Gerekçe |
|---|---|---|
| Identity DH key | **X25519** | DH için optimum; Signal standardı |
| Identity sign key | **Ed25519** | İmza için ayrı tutuluyor (eğitim/test kolaylığı) |
| Signed prekey | **X25519**, Ed25519 ile imzalanır | SPK rotation'da imza yenilenir |
| One-Time prekey | **X25519** | Tek kullanımlık, kullanılınca silinir |
| KDF | **HKDF-SHA-256** | X3DH'nin standart çıktı türetici |
| Symmetric AEAD (Faz 3) | **AES-256-GCM** | Donanım hızlandırması yaygın |
| OPK havuz boyutu | **100** | Signal pratik standardı |
| OPK fallback | **SPK-only** (DH4 atlanır) | Faz 0'da karara bağlandı |
| Wire format | **JSON** + base64url public key'ler | Faz 2'de okunabilirlik > performans |

---

## Faz 2A — Key Bundle Infrastructure

> **Tek cümlelik hedef:** *"İki istemci de cihazda kendi anahtarlarını üretir, public bundle'larını sunucuya yükler; karşı taraf bundle'ı çekebilir, OPK atomik olarak tüketilir."*

### Başarı Kriteri

- [x] `Identity` üretici: IK_dh (X25519) + IK_sig (Ed25519) + SPK (X25519, IK_sig ile imzalı) + 100 OPK (X25519)
- [x] Private key'ler `flutter_secure_storage`'da, plaintext disk'e ASLA yazılmaz
- [x] `POST /api/v1/keys/bundle` — public bundle'ı yükler (private key alanı reddedilir)
- [x] `GET /api/v1/keys/bundle/{user_id}` — bundle döner; OPK havuzunda anahtar varsa biri **atomik** olarak tüketilir + DB'den silinir
- [x] OPK havuzu boşsa fallback: bundle döner ama `one_time_prekey: null` (SPK-only mode)
- [x] Idempotent upload: aynı kullanıcı tekrar upload yaparsa SPK ve OPK güncellenir (key rotation)
- [x] SPK signature istemci tarafından IK_sig ile doğrulanabilir (test bunu kontrol eder)
- [x] Sunucu logları: hiçbir private key field'ı görmez (yoksa zaten reddedilir)
- [x] pytest: **11 yeni test** (upload happy path, fetch consume, atomic distribution, SPK-only fallback, idempotent reupload, 404, forbidden private fields, bad handle, bad length, duplicate opk_id, stats endpoint)

### İş Kırılım Yapısı

#### Server
- [x] `app/db.py` — psycopg connection helper (transaction context manager)
- [x] `app/keys_repo.py` — `upsert_bundle()`, `fetch_bundle_consuming_opk()` (FOR UPDATE SKIP LOCKED), `opk_count()`, `delete_user()`
- [x] `app/api_keys.py` — Blueprint, validation (handle regex, b64u length 32/64, forbidden private_/secret/_priv field reddi)
- [x] `app/server.py` — blueprint mount, MAX_CONTENT_LENGTH 32 KB
- [x] `tests/test_keys_api.py` — 11 test, hepsi yeşil

#### Client
- [x] `pubspec.yaml` — `cryptography: ^2.7.0`, `http: ^1.2.2`
- [x] `lib/crypto/codec.dart` — base64url encode/decode (padding'siz)
- [x] `lib/crypto/identity.dart` — `Identity` (X25519+Ed25519), `SignedPreKey`, `OneTimePreKey`, `PublicKeyBundle`, `FetchedBundle.verifySpkSignature()`
- [x] `lib/storage/secure_keys.dart` — flutter_secure_storage wrapper (identity + spk + opk havuzu, atomik OPK tüketimi)
- [x] `lib/core/keys_api.dart` — `uploadBundle()`, `fetchBundle(handle)`, `opkCount(handle)`
- [x] `lib/ui/identity_screen.dart` — Üret + Yükle + Karşı tarafı çek + İmza doğrula + Wipe; web uyarı banner'ı
- [x] `test/identity_test.dart` — 12 test: B64u, key generation, sign/verify (happy + tampered + wrong key), 100 OPK uniqueness, JSON schema, FetchedBundle parse (with/without OPK), X25519 ECDH wiring

#### Güvenlik
- [x] Server: bundle upload schema validator — sadece beklenen field'lar, byte length limits
- [x] Server: payload başına max boyut (bundle ~ 5KB; rate-limit `flask-limiter` zaten 200/min)
- [x] Client: SPK signature **indirme sonrası verify** (UI'da büyük ✅/❌ gösterilir)
- [x] Server: `forbidden_field` (private_*, *_priv, secret*) recursive reddedilir
- [x] End-to-end smoke: HTTP upload → atomic OPK consume → SPK-only fallback → 404 unknown

### Riskler

| Risk | Azaltım |
|---|---|
| Web'de `flutter_secure_storage` IndexedDB tabanlı, gerçek secure değil | "Web = demo only" notu UI'da, prod web'de kullanıcıyı uyar |
| OPK race condition (iki Alice aynı anda fetch) | DB transaction `FOR UPDATE SKIP LOCKED` ile atomik consume |
| `cryptography` Dart paketi web'de native crypto API kullanmaz | Test ortamında pure-Dart fallback yeterli; prod için `webcrypto` köprüsü Faz 3'te |

---

## Faz 2B — X3DH Handshake ✅ Tamamlandı

> **Tek cümlelik hedef:** *"Alice, Bob'un bundle'ını indirir, X3DH ile `SK` türetir; Bob aynı `SK`'yı bağımsız hesaplar; eşitlik test ile doğrulanır."*

### Başarı Kriteri

- [x] `lib/crypto/x3dh.dart` — `deriveAsInitiator()`, `deriveAsResponder()`
- [x] X3DHHeader wire formatı — `sender_ik`, `sender_ek`, `recipient_spk_id`, `recipient_opk_id`
- [x] OPK varsa DH4 dahil, yoksa SPK-only fallback
- [x] HKDF-SHA-256 ile 32-byte SK türetimi (Signal spec §3.3 uyumlu, salt=32×0x00, info="EE2E X3DH v1")
- [x] `lib/ui/safety_number_screen.dart` — SHA-256(min(IK_A,IK_B)||max(IK_A,IK_B)); 60 haneli ondalık fingerprint

### Tamamlanan dosyalar

| Dosya | Açıklama |
|-------|----------|
| `lib/crypto/x3dh.dart` | X3DH.deriveAsInitiator(), X3DH.deriveAsResponder(), X3DHResult, X3DHHeader |
| `lib/ui/safety_number_screen.dart` | SHA-256 fingerprint, 60 haneli format, doğrulama akışı |

### Retrospektif

**Ne iyi gitti:**
- X3DHHeader JSON serializasyonu (`B64u.encode/decode`) temiz çalıştı.
- OPK tüketimi (`consumeOneTimePreKey`) mevcut `SecureKeyStore` ile sorunsuz entegre oldu.

**Dikkat:**
- SPK imzası doğrulanmadan `deriveAsInitiator()` çağrılmamalı — UI bunu zorunlu kılıyor.
- Web'de `flutter_secure_storage` IndexedDB tabanlı; production için native build gerekir.

---

## Faz 3 — 1:1 E2EE Mesajlaşma ✅ Tamamlandı

> **Tek cümlelik hedef:** *"Socket.IO üzerinden taşınan envelope tamamen opaque ciphertext; sunucu asla plaintext göremez; Double Ratchet ile forward secrecy sağlanır."*

### Başarı Kriteri

- [x] `lib/crypto/ratchet.dart` — `DoubleRatchet` sınıfı
- [x] `initAsSender(sk, bobSpkPublic)` — Alice tarafı ilk DH adımı
- [x] `initAsReceiver(sk, spk)` — Bob tarafı başlatma
- [x] `encrypt(plaintext, [ad])` → `EncryptedMessage` (AES-256-GCM + RatchetHeader)
- [x] `decrypt(msg, [ad])` → plaintext String
- [x] KDF_RK: HKDF-SHA-256, (RK, DH_out) → (yeni RK, CK)
- [x] KDF_CK: HMAC-SHA-256, CK + 0x01/0x02 → (MK, yeni CK) — Signal spec birebir
- [x] DH Ratchet adımı: yeni key pair üret, recv+send zincirleri güncelle
- [x] Skipped key cache — out-of-order teslim; maks 1000 anahtar güvenlik sınırı
- [x] `lib/ui/e2e_chat_screen.dart` — tam E2EE sohbet ekranı
- [x] Wire protokol: `{ee2e:true, v:1, enc:{...}, [x3dh:{...}]}`
- [x] İlk mesajda X3DH header otomatik eklenir, sonraki mesajlarda atlanır
- [x] `lib/ui/connection_screen.dart` → "Faz 3 — 🔐 Şifreli Sohbet Başlat" ana buton

### Tamamlanan dosyalar

| Dosya | Açıklama |
|-------|----------|
| `lib/crypto/ratchet.dart` | DoubleRatchet, RatchetHeader, EncryptedMessage, pure-Dart SHA-256/HMAC |
| `lib/ui/e2e_chat_screen.dart` | E2EChatScreen: X3DH+Ratchet oturum yönetimi, şifreli mesaj gönder/al |
| `lib/ui/connection_screen.dart` | Faz 3 butonu, _connectE2E(), web için Uri.base.origin |

### Deploy

- Flutter web `flutter build web` ile derlenir, `client/build/web/` çıktısı Docker'a mount edilir.
- `docker compose restart app` ile sunucu yeni build'i alır; uygulama `http://localhost:5050`'den açılır.
- Aynı origin üzerinden çalıştığından CORS sorunu yoktur.

### Retrospektif

**Ne iyi gitti:**
- Double Ratchet KDF zincirleri pure Dart ile senkron çalışıyor; async bağımlılığı yok.
- `EncryptedMessage.toJson()` / `fromJson()` Socket.IO envelope'una doğrudan gömüldü, ayrı serializasyon katmanı gerekmedi.
- `sha256Pub()` public metodu `SafetyNumberScreen` ile temiz paylaşım sağladı.
- Web'i Docker üzerinden servis etmek (`Uri.base.origin`) CORS sorununu tamamen ortadan kaldırdı.

**Dikkat:**
- Web'de `flutter_secure_storage` IndexedDB kullanır; sayfa yenilendiğinde Ratchet state sıfırlanır (oturum yeniden kurulur).
- Skipped key cache bellek içi; uygulama yeniden başlatıldığında kaybolur (kabul edilebilir Faz 3 için).
- Out-of-order mesaj limiti 1000 — aşılırsa `StateError` fırlatılır.

---

## Faz 4, 5 (özet)

`YAPILACAKLAR.md` dosyasına bakın. Detay her faz başında bu dokümana eklenecek.
