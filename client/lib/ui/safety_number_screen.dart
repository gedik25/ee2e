import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../crypto/ratchet.dart';
import '../storage/secure_keys.dart';

/// Faz 2B — Safety Number (Fingerprint) Ekranı.
///
/// Signal'ın "Safety Number" (Güvenlik Numarası) özelliğinin MVP'si.
/// SHA-256(IK_A || IK_B) alınır ve 60 haneli ondalık formatta gösterilir.
/// Kullanıcılar bu numarayı güvenli bir kanal üzerinden karşılaştırarak
/// MITM saldırısı olmadığını doğrulayabilir.
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({
    super.key,
    required this.myIdentityKey,
    required this.peerIdentityKey,
    required this.myHandle,
    required this.peerHandle,
  });

  /// Kendi IK DH public key'imiz (32 byte)
  final Uint8List myIdentityKey;

  /// Karşı tarafın IK DH public key'i (32 byte)
  final Uint8List peerIdentityKey;

  final String myHandle;
  final String peerHandle;

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  String? _safetyNumber;
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _compute();
  }

  void _compute() {
    // SHA-256(min(IK_A,IK_B) || max(IK_A,IK_B)) — sıralama determinizm için
    // Her iki taraf da aynı numarayı hesaplamalı (sıra bağımsız)
    final a = widget.myIdentityKey;
    final b = widget.peerIdentityKey;

    // Lexicographic sıralama
    final (first, second) = _lexLess(a, b) ? (a, b) : (b, a);
    final combined = Uint8List(first.length + second.length);
    combined.setRange(0, first.length, first);
    combined.setRange(first.length, combined.length, second);

    final hash = DoubleRatchet.sha256Pub(combined);

    // 60 haneli grup formatı (5'li gruplar, Signal standardı)
    final decimal = _toDecimalGroups(hash);
    setState(() => _safetyNumber = decimal);
  }

  /// Byte dizisini 60 haneli ondalık gruba çevirir.
  String _toDecimalGroups(Uint8List hash) {
    // Her 5 byte → 5 ondalık hane (Signal'ın kullandığı format)
    final groups = <String>[];
    for (var i = 0; i < 30; i += 5) {
      // 5 byte → 40-bit sayı → 5 haneli ondalık (Signal spec)
      if (i + 4 < hash.length) {
        var val = 0;
        for (var j = 0; j < 5; j++) {
          val = val * 256 + hash[i + j];
        }
        groups.add(val.toString().padLeft(5, '0'));
      }
    }
    return groups.join(' ');
  }

  bool _lexLess(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] < b[i]) return true;
      if (a[i] > b[i]) return false;
    }
    return a.length < b.length;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Güvenlik Numarası'),
        actions: [
          if (_safetyNumber != null)
            IconButton(
              tooltip: 'Kopyala',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _safetyNumber!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Güvenlik numarası kopyalandı')),
                );
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Açıklama kartı
            Card(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.security, color: scheme.onPrimaryContainer),
                        const SizedBox(width: 8),
                        Text(
                          'Konuşma Doğrulama',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: scheme.onPrimaryContainer,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Bu güvenlik numarasını, karşı tarafla güvenli bir '
                      'kanal üzerinden (yüz yüze, telefon vb.) karşılaştırın. '
                      'Numaralar eşleşiyorsa iletişiminiz güvende.',
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Kullanıcı isimleri
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _UserChip(label: widget.myHandle, icon: Icons.person),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(Icons.lock_outline),
                ),
                _UserChip(label: widget.peerHandle, icon: Icons.person_outline),
              ],
            ),
            const SizedBox(height: 32),

            // Güvenlik numarası
            if (_safetyNumber == null)
              const CircularProgressIndicator()
            else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                decoration: BoxDecoration(
                  color: _verified
                      ? Colors.green.withValues(alpha: 0.15)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _verified ? Colors.green : scheme.outline,
                    width: _verified ? 2 : 1,
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      _safetyNumber!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    if (_verified) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.verified, color: Colors.green),
                          const SizedBox(width: 6),
                          Text(
                            'Doğrulandı',
                            style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Doğrulama butonu
              if (!_verified)
                FilledButton.icon(
                  onPressed: () {
                    showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Numaraları Karşılaştırdınız mı?'),
                        content: const Text(
                          'Karşı tarafla güvenlik numarasını güvenli bir kanaldan '
                          '(yüz yüze veya sesli arama) karşılaştırdıysanız ve '
                          'numaralar eşleşiyorsa "Doğrula"ya basın.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Henüz Değil'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Doğrula ✓'),
                          ),
                        ],
                      ),
                    ).then((confirmed) {
                      if (confirmed == true) {
                        setState(() => _verified = true);
                      }
                    });
                  },
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Numaraları Karşılaştırdım, Doğrula'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => setState(() => _verified = false),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Doğrulamayı Sıfırla'),
                ),

              const SizedBox(height: 32),

              // Teknik bilgi
              ExpansionTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Teknik Detay'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'SHA-256(IK_A || IK_B) alınarak 60 haneli ondalık formata dönüştürüldü.\n'
                      'Her iki tarafın kimlik anahtarları (Identity Key - IK) aynı algoritmadan '
                      'geçirildiği için numaralar eşleşmeli. Eşleşmiyorsa MITM saldırısı mümkün.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UserChip extends StatelessWidget {
  const _UserChip({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
    );
  }
}
