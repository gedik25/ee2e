# EE2E — Uçtan Uca Şifreli Mesajlaşma Sistemi

> Zero-Knowledge prensibiyle tasarlanmış, Flutter istemcisi ve Flask-SocketIO sunucusu üzerine kurulu, Signal Protokolü (X3DH + Double Ratchet) tabanlı uçtan uca şifreli mesajlaşma altyapısı.

## Mevcut Durum

| Faz | Ad | Durum |
|-----|----|-------|
| 0 | Hazırlık & Mimari Dokümantasyonu | ✅ Tamamlandı |
| 1 | Altyapı + Dockerize Backend | ✅ Tamamlandı |
| 2A | Key Bundle Infrastructure | ✅ Tamamlandı |
| 2B | X3DH Handshake | ✅ Tamamlandı |
| 3 | 1:1 E2EE Mesajlaşma (Double Ratchet + AES-256-GCM) | ✅ Tamamlandı |
| 4 | Grup + Metadata Hardening | ⬜ Beklemede |
| 5 | MLS + Platform Optimizasyonları | ⬜ Beklemede |

Detaylar için `PHASES.md` ve `YAPILANLAR.md` dosyalarına bakın.

## Repo Yapısı

```
ee2e/
├── README.md                ← Bu dosya
├── PHASES.md                ← Faz planı + durum takibi (yaşayan doküman)
├── YAPILANLAR.md            ← Tamamlanan işlerin özeti
├── YAPILACAKLAR.md          ← Bekleyen fazların planı (Faz 4, 5)
├── ARCHITECTURE.md          ← Sistem mimarisi
├── SISTEM-MIMARISI.md       ← Detaylı sistem mimarisi
├── docs/
│   ├── security-pillars.md  ← 4 güvenlik sütunu detayları
│   ├── threat-model.md      ← Tehdit modeli (STRIDE)
│   └── glossary.md          ← Terimler sözlüğü (X3DH, OPK, IK vb.)
├── server/                  ← Flask-SocketIO + PostgreSQL + Docker
│   ├── app/                 ← Python uygulama kodu
│   ├── db/schema.sql        ← Veritabanı şeması
│   ├── docker-compose.yml
│   ├── Dockerfile
│   └── .env.example
└── client/                  ← Flutter web/masaüstü uygulaması
    └── lib/
        ├── crypto/          ← x3dh.dart, ratchet.dart, identity.dart, codec.dart
        ├── core/            ← socket_client.dart, keys_api.dart
        ├── storage/         ← secure_keys.dart
        └── ui/              ← e2e_chat_screen.dart, safety_number_screen.dart, …
```

## Teknoloji Yığını

| Katman | Teknoloji |
|--------|-----------|
| İstemci | Flutter (Dart) + `cryptography` paketi + `flutter_secure_storage` |
| Kripto (istemci) | X3DH + Double Ratchet + AES-256-GCM + Ed25519/X25519 |
| Gerçek-zamanlı | Socket.IO (WebSocket) |
| Sunucu | Python 3.12 + Flask + Flask-SocketIO |
| Veritabanı | PostgreSQL 16 (yalnızca **public** key bundle'lar) |
| Konteynerizasyon | Docker + docker-compose |
| Kripto (sunucu) | **YOK** — sunucu plaintext'e veya private key'e asla dokunamaz |

## Güvenlik Sütunları

1. **Zero-Knowledge** — Sunucu hiçbir private key'e veya plaintext mesaja dokunamaz.
2. **Ephemeral Storage** — Mesajlar iletildiği an RAM'den silinir; disk'e yazılmaz.
3. **Forward Secrecy** — Double Ratchet ile her mesaj farklı anahtarla şifrelenir.
4. **Signal Protokolü** — X3DH handshake + Double Ratchet, endüstri standardı.

## Hızlı Başlangıç

### 1. Sunucuyu başlat (Docker)
```bash
cd server
cp .env.example .env        # gerekirse değerleri düzenle
docker compose up -d
```

### 2. Flutter web'i derle ve sunucuya yükle
```bash
cd client
flutter pub get
flutter build web --no-wasm-dry-run
cd ../server
docker compose restart app
```

### 3. Uygulamayı aç
Tarayıcıda **`http://localhost:5050`** adresini aç.

### 4. İki kullanıcıyla test et
- **Sekme 1:** Faz 2A → handle `kadir` → Kimlik Üret → Bundle Yükle → Faz 3 Şifreli Sohbet
- **Sekme 2:** Faz 2A → handle `ali` → Kimlik Üret → Bundle Yükle → Faz 3 Şifreli Sohbet
- Her iki sekmede karşılıklı peer handle'ını girerek bağlan ve mesajlaş 🔐
