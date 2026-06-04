# EE2E — Yapılacaklar (Teknik Borç & Gelecek Planı)

> Bu belge **tüm ana fazlar (Faz 0 - Faz 5) tamamlandıktan sonra** kalan küçük teknik borçları ve üretim (production) ortamı için planlanan geliştirmeleri listeler.

---

## Proje Durumu: Tüm Fazlar Tamamlandı!

| Sıra | Faz | Ad | Durum |
|------|-----|-----|-------|
| 1 | **0** | Hazırlık & Mimari Dokümantasyonu | ✅ Tamamlandı |
| 2 | **1** | Altyapı + Dockerize Backend | ✅ Tamamlandı |
| 3 | **2A** | Key Bundle Dağıtımı | ✅ Tamamlandı |
| 4 | **2B** | X3DH Handshake | ✅ Tamamlandı |
| 5 | **3** | 1:1 E2EE Mesajlaşma (Double Ratchet) | ✅ Tamamlandı |
| 6 | **4** | Grup Sohbeti & Metadata Sertleştirme (Sealed Sender) | ✅ Tamamlandı |
| 7 | **5** | MLS (TreeKEM) & Çoklu Platform Desteği | ✅ Tamamlandı |

---

## Kalan Teknik Borçlar ve Üretim (Production) Planı

Ana fazlar tamamlanmış olsa da, sistemi tam anlamıyla güvenli ve ölçeklenebilir bir üretim ortamına taşımak için yapılması planlanan iyileştirmeler aşağıdadır:

### 1. Güçlü Kimlik Doğrulama (Socket Auth)
- [ ] Bağlantı anında sadece `client_id` almak yerine, istemcinin Identity Sign Key'i (`IK_sig`) ile imzalanmış tek kullanımlık bir challenge-response auth akışının kurulması.

### 2. Kalıcı / Ölçeklenebilir Kuyruk (Redis)
- [ ] Sunucudaki in-memory ephemeral kuyruğun, sunucu yeniden başlatıldığında verilerin kaybolmaması ve yatay ölçekleme (horizontal scaling) yapılabilmesi için Redis tabanlı bir kuyruk mimarisine taşınması.

### 3. Web Platformu Güvenlik İyileştirmesi
- [ ] Flutter web platformunda `flutter_secure_storage` IndexedDB kullandığından, tarayıcıda private key'lerin daha güvenli saklanabilmesi için WebCrypto veya donanımsal koruma köprülerinin araştırılıp entegre edilmesi.

### 4. Push Bildirimlerinin Canlıya Alınması
- [ ] İstemci ve sunucudaki mock/stub push servislerinin gerçek FCM (Firebase Cloud Messaging) veya APNs (Apple Push Notification service) ile bağlanması.

### 5. Sürekli Entegrasyon (CI/CD)
- [ ] GitHub Actions veya GitLab CI ile otomatik docker build smoke testleri ve pytest/flutter test birim testlerinin çalıştırılması.
