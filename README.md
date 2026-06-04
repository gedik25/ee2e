# EE2E — Uçtan Uca Şifreli Mesajlaşma Sistemi

[![Licence](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-%E2%89%A53.22.0-blue.svg)](https://flutter.dev)
[![Python](https://img.shields.io/badge/Python-3.12-green.svg)](https://www.python.org/)
[![Docker](https://img.shields.io/badge/Docker-Supported-blue.svg)](https://www.docker.com/)

Zero-Knowledge (Sıfır-Bilgi) prensibiyle tasarlanmış, **Flutter** istemcisi ve **Flask-SocketIO** sunucusu üzerine kurulu, modern kriptografik protokolleri (X3DH, Double Ratchet, Sealed Sender, TreeKEM/MLS) uçtan uca uygulayan güvenli bir mesajlaşma altyapısıdır.

---

## 📖 İçindekiler
- [Sistem Mimarisi](#-sistem-mimarisi)
- [Kriptografik Güvenlik Protokolleri](#-kriptografik-güvenlik-protokolleri)
- [Güvenlik Sütunlarımız (Vazgeçilmezler)](#-güvenlik-sütunlarımız-vazgeçilmezler)
- [Teknoloji Yığını](#-teknoloji-yığını)
- [Proje Klasör Yapısı](#-proje-klasör-yapısı)
- [Sistem Gereksinimleri](#-sistem-gereksinimleri)
- [Kurulum ve Çalıştırma](#-kurulum-ve-çalıştırma)
  - [1. Sunucu Kurulumu (Docker ile - Önerilen)](#1-sunucu-kurulumu-docker-ile---önerilen)
  - [2. Sunucu Kurulumu (Yerel Python Ortamı ile)](#2-sunucu-kurulumu-yerel-python-ortamı-ile)
  - [3. İstemci Kurulumu (Flutter)](#3-istemci-kurulumu-flutter)
- [Test ve Doğrulama](#-test-ve-doğrulama)
  - [İstemci Testleri](#istemci-testleri)
  - [Sunucu Testleri](#sunucu-testleri)
  - [Sızıntı ve Güvenlik Testleri](#sızıntı-ve-güvenlik-testleri)

---

## 🏗 Sistem Mimarisi

EE2E, istemcinin tüm şifreleme/şifre çözme işlemlerini üstlendiği, sunucunun ise sadece şifreli paketleri yönlendirdiği (Kör İletim) 3 katmanlı bir mimariye sahiptir.

```
┌──────────────────────────────────────────────────────────────────┐
│                    İSTEMCİ KATMANI (Flutter)                     │
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
│  │  Key Management │  │  Crypto Engine   │  │  Local Storage  │  │
│  │  IK / SPK / OPK │  │  X3DH + Ratchet  │  │  Secure Storage │  │
│  └─────────────────┘  └──────────────────┘  └─────────────────┘  │
│                              │  ▲                                │
│                  (yalnızca   │  │   plaintext                    │
│                   şifreli    │  │   ASLA istemciden              │
│                   payload)   ▼  │   dışarı çıkmaz)               │
└──────────────────────────────│──│────────────────────────────────┘
                               │  │
                           wss://│  │ wss://   (TLS 1.3)
                               ▼  │
┌──────────────────────────────────────────────────────────────────┐
│                İLETİŞİM KATMANI (Socket.IO / WSS)                │
│         "Kör" iletim — sadece zarfı taşır, içeriği göremez       │
└──────────────────────────────│──│────────────────────────────────┘
                               ▼  │
┌──────────────────────────────────────────────────────────────────┐
│              SUNUCU KATMANI (Docker / Flask)                     │
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
│  │ SocketIO Router │  │  Key Bundle API  │  │  Ephemeral Q.   │  │
│  │ (room-based)    │  │  (HTTP REST)     │  │  (RAM, TTL)     │  │
│  └─────────────────┘  └──────────────────┘  └─────────────────┘  │
│           │                    │                                 │
│           ▼                    ▼                                 │
│  ┌──────────────────────────────────────┐                        │
│  │   PostgreSQL — sadece PUBLIC keys    │                        │
│  │   (IK_pub, SPK_pub + sig, OPK_pub[]) │                        │
│  └──────────────────────────────────────┘                        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 🔐 Kriptografik Güvenlik Protokolleri

EE2E, sektör standardı modern şifreleme şemalarını sırasıyla uygular:

1. **X3DH (Extended Triple Diffie-Hellman):**
   * Taraflar arasında güvenli, asenkron ve kimliği doğrulanmış bir ilk ortak anahtar (Shared Secret) türetmek için kullanılır.
   * **IK (Identity Key)**, **SPK (Signed Prekey)** ve tek kullanımlık **OPK (One-Time Prekey)** bileşenlerini kullanarak ortadaki adam (MITM) saldırılarını engeller. Sunucu OPK'ları tek kullanımlık olarak dağıtır ve tüketilen anahtar sistemden silinir.
2. **Double Ratchet (Çift Yönlü Çark):**
   * X3DH ile türetilen ortak anahtar üzerinden oturum boyu her mesajda anahtarların yenilenmesini sağlar.
   * **Diffie-Hellman Ratchet** ve **Symmetric KDF Chain Ratchet** entegrasyonu sayesinde hem geriye dönük güvenliği (**Forward Secrecy**) hem de geleceğe yönelik güvenliği (**Break-in Recovery / Post-Compromise Security**) garanti eder.
3. **Sealed Sender (Mühürlü Gönderici):**
   * Mesajı kimin gönderdiği bilgisini (Metadata) sunucudan gizler.
   * Gönderici bilgisi, alıcının Identity Public Key'i kullanılarak mühürlenir (şifrelenir). Sunucu sadece alıcı bilgisini görerek mesajı teslim eder; teslim alan istemci kendi özel anahtarıyla mührü açarak göndericiyi doğrular.
4. **TreeKEM & Sender Keys (MLS Altyapısı):**
   * Grup mesajlaşmalarında yüksek performans ve güvenlik sağlamak için geliştirilmiştir.
   * **TreeKEM**, ikili ağaç (binary tree) yapısında grup üyelerini yönetir. Bir üye gruba katıldığında veya çıktığında sadece kendi yaprağından köke giden yoldaki düğüm anahtarlarını günceller ($O(\log N)$ karmaşıklık).
   * **Sender Keys** ise büyük gruplarda verimli 1-to-many (bir kişiden çok kişiye) şifreli mesaj yayını yapmayı sağlar.

---

## 🛡 Güvenlik Sütunlarımız (Vazgeçilmezler)

* **Zero-Knowledge (Sıfır-Bilgi):** Sunucu, hiçbir private key'e veya plaintext (şifrelenmemiş) mesaj verisine asla erişemez. Tüm şifreleme ve deşifre işlemleri istemci cihazlarında gerçekleşir.
* **Ephemeral Storage (Geçici Depolama):** Mesajlar sunucu diskine yazılmaz. Alıcı çevrimiçi ise mesaj anında iletilir ve bellekten silinir. Alıcı çevrimdışı ise mesaj geçici bir kuyrukta (ephemeral queue) TTL (Time-To-Live) süresi boyunca tutulur ve iletildiği an yok edilir.
* **Forward Secrecy (İleriye Yönelik Gizlilik):** Geçmişe yönelik mesajların korunması amacıyla, bir anahtar ele geçirilse dahi önceki mesajlar deşifre edilemez.
* **Docker Isolation (Docker İzolasyonu):** Backend bileşenleri (Flask uygulaması ve PostgreSQL veritabanı) hem birbirinden hem de ana işletim sisteminden tamamen izole bir şekilde çalışır.

---

## 💻 Teknoloji Yığını

| Katman | Teknoloji | Açıklama |
| :--- | :--- | :--- |
| **İstemci (Client)** | Flutter (Dart 3.x) | Android, iOS, macOS, Windows ve Web desteği |
| **Kripto Kütüphanesi** | `cryptography` | X25519, Ed25519, AES-256-GCM, HKDF, SHA-256 |
| **Yerel Güvenli Depo** | `flutter_secure_storage` | Cihaz düzeyinde anahtarların şifreli saklanması |
| **Haberleşme** | Socket.IO Client / Server | Gerçek zamanlı çift yönlü WebSocket iletişimi |
| **Sunucu (Server)** | Python 3.12 + Flask + Flask-SocketIO | WSGI sunucusu olarak `eventlet` altyapısı |
| **Veritabanı** | PostgreSQL 16 | Yalnızca kullanıcı handle'ları ve public key bundle'lar |
| **Konteynerizasyon** | Docker & Docker Compose | İzole, taşınabilir servis yönetimi |

---

## 📂 Proje Klasör Yapısı

```text
ee2e/
├── client/                     # Flutter İstemci Uygulaması
│   ├── lib/
│   │   ├── core/               # Soket istemcisi, push ve lokal depo servisleri
│   │   ├── crypto/             # Kripto motoru (X3DH, Double Ratchet, TreeKEM vb.)
│   │   ├── storage/            # Secure key storage yönetimi
│   │   ├── ui/                 # Sohbet, kimlik ve güvenlik numarası arayüzleri
│   │   └── main.dart           # Uygulama başlangıç noktası
│   └── test/                   # İstemci kripto ve widget birim testleri
│
├── server/                     # Flask + Socket.IO Sunucu Uygulaması
│   ├── app/                    # Sunucu API, soket yönlendirici ve anahtar deposu
│   ├── db/                     # PostgreSQL veritabanı şeması (`schema.sql`)
│   ├── tests/                  # API, soket ve sızıntı doğrulama testleri
│   ├── Dockerfile              # Çok aşamalı (multi-stage) güvenli Docker üretimi
│   ├── docker-compose.yml      # Servislerin (app + db) orkestrasyonu
│   ├── Makefile                # Kolay yönetim komutları
│   └── requirements.txt        # Sunucu bağımlılıkları (Flask, eventlet vb.)
│
├── docs/                       # Güvenlik sütunları, tehdit modelleri ve sözlük
└── ARCHITECTURE.md             # Yaşayan sistem mimarisi dokümanı
```

---

## ⚙️ Sistem Gereksinimleri

Projeyi yerelinizde derlemek ve çalıştırmak için aşağıdaki bileşenlerin yüklü olması gerekir:

* **Flutter SDK:** `>= 3.22.0` (Dart `>= 3.4.0 < 4.0.0`)
* **Python:** `3.12`
* **Docker & Docker Compose** (Sunucuyu Docker ile çalıştırmak için)
* **PostgreSQL** (Sunucuyu Docker kullanmadan yerel çalıştırmak için)
* **Make** (Kolaylaştırılmış terminal komutları için - opsiyonel)

---

## 🚀 Kurulum ve Çalıştırma

### 1. Sunucu Kurulumu (Docker ile - Önerilen)

En hızlı ve izole kurulum yöntemi Docker Compose kullanmaktır.

1. `server` klasörüne geçin:
   ```bash
   cd server
   ```
2. `.env.example` dosyasını `.env` olarak kopyalayın ve gerekli şifreleri düzenleyin:
   ```bash
   make env
   # Veya manuel: cp .env.example .env
   ```
3. Servisleri derleyin ve arka planda çalıştırın:
   ```bash
   make up
   # Veya manuel: docker compose up -d --build
   ```
4. Sunucunun durumunu kontrol edin:
   * Tarayıcıdan veya curl ile: `http://localhost:5050/health` (Docker üzerinde 5050 portu hosta açılmıştır, konteyner içinde 5000 çalışır).
   * Logları izlemek için: `make logs`

### 2. Sunucu Kurulumu (Yerel Python Ortamı ile)

Docker kullanmadan doğrudan yerel makinenizde çalıştırmak istiyorsanız:

1. `server` klasöründe sanal ortam oluşturun ve aktif edin:
   ```bash
   cd server
   python3 -m venv venv
   source venv/bin/activate  # Windows için: venv\Scripts\activate
   ```
2. Bağımlılıkları yükleyin:
   ```bash
   pip install -r requirements.txt
   ```
3. `.env` dosyasını oluşturun ve veritabanı ayarlarını yapın:
   ```bash
   cp .env.example .env
   ```
   * *Not:* Yerel PostgreSQL sunucunuzun açık olduğundan ve `.env` içindeki `DATABASE_URL`'nin yerel veritabanınıza baktığından emin olun.
4. Veritabanı şemasını uygulayın:
   ```bash
   psql -U <postgres_user> -d <db_name> -f db/schema.sql
   ```
5. Sunucuyu başlatın:
   ```bash
   python -m app
   ```
   * Sunucu varsayılan olarak `http://127.0.0.1:5000` adresinden ayağa kalkacaktır. Sağlık kontrolü: `http://127.0.0.1:5000/health`

### 3. İstemci Kurulumu (Flutter)

1. `client` klasörüne geçin:
   ```bash
   cd client
   ```
2. Bağımlılıkları çekin:
   ```bash
   flutter pub get
   ```
3. İstemciyi çalıştırmak istediğiniz platforma göre başlatın:
   * **Web Platformu için (Geliştirme):**
     ```bash
     flutter run -d chrome
     ```
   * **macOS / Windows / Linux desktop için:**
     ```bash
     flutter run -d macos  # ya da windows/linux
     ```
   * **Mobil Cihaz veya Simülatör için:**
     ```bash
     flutter run
     ```
   * *Not:* İstemci arayüzünde sunucu adresi olarak Docker kullanıyorsanız `http://localhost:5050` veya yerel çalıştırıyorsanız `http://localhost:5000` adresini girebilirsiniz.

---

## 🧪 Test ve Doğrulama

Sistem bileşenlerinin doğruluğunu kontrol etmek için birim ve entegrasyon testleri mevcuttur.

### İstemci Testleri

Kriptografik motoru (Double Ratchet zincirleri, X3DH handshake mantığı, TreeKEM ağaç operasyonları vb.) doğrulamak için `client` klasöründe:

```bash
cd client
flutter test
```

### Sunucu Testleri

Sunucu uç noktalarını (REST Key Bundle API, Socket.IO Relay vb.) test etmek için:

* **Docker Konteyner İçinde (Önerilen):**
  ```bash
  cd server
  make test
  # Veya manuel: docker compose exec app python -m pytest -q
  ```
* **Yerel Python Ortamında:**
  ```bash
  cd server
  pytest
  ```

### Sızıntı ve Güvenlik Testleri

Sunucunun loglarına hiçbir şekilde açık metin (plaintext) mesaj verisinin sızmadığını doğrulamak için özel bir entegrasyon testi mevcuttur. 

Bu test, rastgele bir mesaj göndererek sunucu loglarını tarar ve hassas verilerin loglarda yer almadığından emin olur:

```bash
cd server
make test-no-leak
```

---

## 📄 Lisans

Bu proje **MIT Lisansı** altında lisanslanmıştır. Detaylar için `LICENSE` dosyasına göz atabilirsiniz.
