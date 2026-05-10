# EE2E — Faz Planı ve Durum Takibi

> **Yaşayan doküman.** Her faz sonunda checkbox'lar güncellenir, kazanılan dersler "Retrospektif" bölümüne eklenir.

| Faz | Ad                                  | Durum         | Hedef Çıktı                                              |
|-----|-------------------------------------|---------------|----------------------------------------------------------|
| 0   | Hazırlık & Mimari Dokümantasyonu   | ✅ Tamamlandı  | `ARCHITECTURE.md`, `PHASES.md`, repo iskeleti           |
| 1   | Altyapı + Dockerize Backend         | ✅ Tamamlandı  | macOS↔Chrome local + ngrok üzerinden uzak istemci ile mesajlaşma doğrulandı |
| 2   | Identity & Key Management           | ⬜ Beklemede  | X3DH handshake çalışır                                  |
| 3   | 1:1 E2EE Mesajlaşma                 | ⬜ Beklemede  | Gerçek şifreli mesaj gidip gelsin                       |
| 4   | Grup + Metadata Hardening           | ⬜ Beklemede  | Sender Keys + Padding + Sealed Sender                   |
| 5   | MLS + Platform Optimizasyonları     | ⬜ Beklemede  | TreeKEM grup, push bildirim, multi-platform             |

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

## Faz 2 — Identity & Key Management (özet)

**Hedef:** İki istemci hiç önceden konuşmamış olsa bile X3DH üzerinden ortak gizli (SK) türetebilsin.

Detayları Faz 1 bittikten sonra açacağız.

---

## Faz 3, 4, 5 (özet)

`ARCHITECTURE.md` "Bileşen Sorumlulukları" bölümüne bakın. Detay her faz başında bu dokümana eklenecek.
