import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/socket_client.dart';
import '../storage/secure_keys.dart';
import 'chat_screen.dart';
import 'e2e_chat_screen.dart';
import 'identity_screen.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _serverCtrl = TextEditingController();
  final _clientIdCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Web'de uygulamanın kendi origin'ini kullan (localhost:5050 üzerinden açıldığında otomatik)
    // Diğer platformlarda sabit localhost:5050
    _serverCtrl.text = kIsWeb ? Uri.base.origin : 'http://localhost:5050';
    _clientIdCtrl.text = const Uuid().v4().substring(0, 8);
    _loadSavedHandle();
  }

  Future<void> _loadSavedHandle() async {
    final store = SecureKeyStore();
    final identity = await store.loadIdentity();
    if (identity != null && mounted) {
      setState(() {
        _clientIdCtrl.text = identity.handle;
      });
    }
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _clientIdCtrl.dispose();
    super.dispose();
  }

  void _connect() {
    final server = _serverCtrl.text.trim();
    final clientId = _clientIdCtrl.text.trim();
    if (server.isEmpty || clientId.isEmpty) return;

    final client = SocketClient(serverUrl: server, clientId: clientId);
    client.connect();

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(client: client),
    ));
  }

  void _connectE2E() {
    final server = _serverCtrl.text.trim();
    final clientId = _clientIdCtrl.text.trim();
    if (server.isEmpty || clientId.isEmpty) return;

    final client = SocketClient(serverUrl: server, clientId: clientId);
    client.connect();

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => E2EChatScreen(client: client, serverUrl: server),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EE2E — Bağlantı')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Faz 1 — İletim Doğrulama',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Bu ekran şifreleme öncesi iletim hattını test eder.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _serverCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Sunucu URL (http/https)',
                    helperText: 'Android emulator: 10.0.2.2  •  Gerçek cihaz: ngrok URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _clientIdCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Client ID',
                    helperText: 'Karşı taraf bu ID ile sana mesaj atacak',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                // Faz 3: E2EE Sohbet (Ana buton)
                FilledButton.icon(
                  onPressed: _connectE2E,
                  icon: const Icon(Icons.lock),
                  label: const Text('Faz 3 — 🔐 Şifreli Sohbet Başlat'),
                ),
                const SizedBox(height: 8),
                // Faz 1: Plaintext sohbet (test amaçlı)
                OutlinedButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.link),
                  label: const Text('Faz 1 — Şifresiz Bağlan (Test)'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    final url = _serverCtrl.text.trim();
                    if (url.isEmpty) return;
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => IdentityScreen(serverUrl: url),
                    ));
                  },
                  icon: const Icon(Icons.vpn_key_outlined),
                  label: const Text('Faz 2A — Anahtar Yönetimi'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
