import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../models/ssh_host.dart';

enum ConnectMode { terminal, sftp }

class ConnectResult {
  final SSHClient client;
  final SSHSession? session; // non-null for terminal mode
  final SftpClient? sftp;   // non-null for sftp mode
  final String host;
  final String username;
  final ConnectMode mode;

  ConnectResult({
    required this.client,
    this.session,
    this.sftp,
    required this.host,
    required this.username,
    required this.mode,
  });
}

Future<ConnectResult?> showConnectDialog(BuildContext context) {
  return showDialog<ConnectResult>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => const _ConnectDialog(),
  );
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog();

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  List<SshHost> _savedHosts = [];
  SshHost? _selectedHost;

  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();

  bool _useKey = false;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    parseSshConfig().then((hosts) {
      if (mounted) setState(() => _savedHosts = hosts);
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _keyCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  void _selectHost(SshHost h) {
    setState(() {
      _selectedHost = h;
      _hostCtrl.text = h.hostname;
      _portCtrl.text = h.port.toString();
      _userCtrl.text = h.user ?? '';
      if (h.identityFile != null) {
        _useKey = true;
        _keyCtrl.text = h.identityFile!;
      } else {
        _useKey = false;
        _keyCtrl.clear();
      }
      _passphraseCtrl.clear();
      _passCtrl.clear();
    });
  }

  Future<void> _connect(ConnectMode mode) async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    final keyPath = _keyCtrl.text.trim();
    final passphrase = _passphraseCtrl.text;

    if (host.isEmpty || user.isEmpty) {
      setState(() => _error = 'Host and username are required.');
      return;
    }

    setState(() { _connecting = true; _error = null; });

    SSHClient? client;
    try {
      // ── Load identities ──────────────────────────────────────────────────
      List<SSHKeyPair>? identities;

      if (_useKey) {
        if (keyPath.isEmpty) {
          setState(() { _connecting = false; _error = 'Enter the path to your private key.'; });
          return;
        }
        final f = File(keyPath);
        if (!await f.exists()) {
          setState(() { _connecting = false; _error = 'Key file not found:\n$keyPath'; });
          return;
        }
        try {
          identities = SSHKeyPair.fromPem(
            await f.readAsString(),
            passphrase.isNotEmpty ? passphrase : null,
          );
          if (identities.isEmpty) {
            setState(() { _connecting = false; _error = 'Could not parse key from:\n$keyPath'; });
            return;
          }
        } catch (e) {
          setState(() {
            _connecting = false;
            _error = 'Failed to load key: ${_simplify(e)}\n'
                'If the key is encrypted, enter its passphrase below.';
          });
          return;
        }
      } else {
        // Auto-detect unencrypted default keys
        final home = Platform.environment['HOME'] ?? '';
        for (final p in [
          '$home/.ssh/id_ed25519',
          '$home/.ssh/id_rsa',
          '$home/.ssh/id_ecdsa',
        ]) {
          final f = File(p);
          if (await f.exists()) {
            try {
              identities = SSHKeyPair.fromPem(await f.readAsString());
              if (identities.isNotEmpty) break;
            } catch (_) {
              identities = null;
            }
          }
        }
      }

      // ── Connect & authenticate (auth error surfaces here immediately) ────
      final socket = await _NoDelaySocket.connect(host, port,
          timeout: const Duration(seconds: 10));

      client = SSHClient(
        socket,
        username: user,
        identities: identities,
        onPasswordRequest: pass.isNotEmpty ? () => pass : null,
      );

      SSHSession? session;
      SftpClient? sftp;

      if (mode == ConnectMode.terminal) {
        session = await client
            .shell(pty: const SSHPtyConfig(width: 80, height: 24, type: 'xterm-256color'))
            .timeout(const Duration(seconds: 15));
      } else {
        sftp = await client.sftp().timeout(const Duration(seconds: 15));
      }

      if (!mounted) {
        client.close();
        return;
      }

      Navigator.of(context).pop(ConnectResult(
        client: client,
        session: session,
        sftp: sftp,
        host: host,
        username: user,
        mode: mode,
      ));
    } catch (e) {
      client?.close();
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = _friendlyError(e);
        });
      }
    }
  }

  String _simplify(Object e) =>
      e.toString().replaceAll('Exception: ', '').replaceAll('Error: ', '');

  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('userauth') || s.contains('authentication') || s.contains('permission')) {
      return 'Authentication failed.\n'
          '• Wrong password or key not in authorized_keys\n'
          '• If using a key, verify the public key is on the server';
    }
    if (s.contains('refused')) return 'Connection refused — check host and port.';
    if (s.contains('timeout') || s.contains('timedout')) {
      return 'Connection timed out — host unreachable.';
    }
    if (s.contains('no route') || s.contains('nodename') || s.contains('socketexception')) {
      return 'Host not found — check the hostname.';
    }
    return _simplify(e);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: 480,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _connecting ? _buildConnecting() : _buildForm(),
          ),
        ),
      ),
    );
  }

  Widget _buildConnecting() {
    return const SizedBox(
      height: 120,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Color(0xFF2472C8), strokeWidth: 2),
          SizedBox(height: 16),
          Text('Connecting…',
              style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'New SSH Connection',
          style: TextStyle(
              color: Color(0xFFD4D4D4),
              fontSize: 15,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 20),

        // ── Saved hosts ────────────────────────────────────────────────────
        if (_savedHosts.isNotEmpty) ...[
          const _Label('Saved Hosts'),
          const SizedBox(height: 6),
          _SavedHostList(
            hosts: _savedHosts,
            selected: _selectedHost,
            onSelect: _selectHost,
          ),
          const SizedBox(height: 16),
          const Divider(color: Color(0xFF3A3A3A), height: 1),
          const SizedBox(height: 16),
        ],

        // ── Host / Port / User ─────────────────────────────────────────────
        Row(children: [
          Expanded(child: _Field(label: 'Hostname / IP', ctrl: _hostCtrl)),
          const SizedBox(width: 8),
          SizedBox(
              width: 68,
              child: _Field(
                  label: 'Port',
                  ctrl: _portCtrl,
                  inputType: TextInputType.number)),
        ]),
        const SizedBox(height: 10),
        _Field(label: 'Username', ctrl: _userCtrl),
        const SizedBox(height: 14),

        // ── Auth method ────────────────────────────────────────────────────
        Row(children: [
          _RadioOption(
              label: 'Password',
              selected: !_useKey,
              onTap: () => setState(() => _useKey = false)),
          const SizedBox(width: 20),
          _RadioOption(
              label: 'SSH Key',
              selected: _useKey,
              onTap: () => setState(() => _useKey = true)),
        ]),
        const SizedBox(height: 10),

        if (!_useKey)
          _Field(label: 'Password', ctrl: _passCtrl, obscure: true)
        else ...[
          _Field(
              label: 'Private Key Path',
              ctrl: _keyCtrl,
              hint: '~/.ssh/id_rsa'),
          const SizedBox(height: 10),
          _Field(
              label: 'Key Passphrase (leave empty if none)',
              ctrl: _passphraseCtrl,
              obscure: true),
        ],

        // ── Error ──────────────────────────────────────────────────────────
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6E67).withAlpha(25),
              borderRadius: BorderRadius.circular(4),
              border:
                  Border.all(color: const Color(0xFFFF6E67).withAlpha(80)),
            ),
            child: Text(_error!,
                style: const TextStyle(
                    color: Color(0xFFFF6E67), fontSize: 12, height: 1.5)),
          ),
        ],

        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFF8E8E8E))),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _connect(ConnectMode.sftp),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF5E5E5E)),
                foregroundColor: const Color(0xFFC7C7C7),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
              ),
              child: const Text('Open SFTP'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () => _connect(ConnectMode.terminal),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2472C8),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
              ),
              child: const Text('Connect'),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _SavedHostList extends StatelessWidget {
  const _SavedHostList(
      {required this.hosts,
      required this.selected,
      required this.onSelect});

  final List<SshHost> hosts;
  final SshHost? selected;
  final ValueChanged<SshHost> onSelect;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 130),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: hosts.length,
        itemBuilder: (_, i) {
          final h = hosts[i];
          final active = selected?.alias == h.alias;
          return InkWell(
            onTap: () => onSelect(h),
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0xFF2472C8).withAlpha(70)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(children: [
                const Icon(Icons.computer,
                    size: 13, color: Color(0xFF686868)),
                const SizedBox(width: 8),
                Text(h.alias,
                    style: const TextStyle(
                        color: Color(0xFFC7C7C7), fontSize: 13)),
                const SizedBox(width: 8),
                Text(h.displayInfo,
                    style: const TextStyle(
                        color: Color(0xFF686868), fontSize: 11)),
                if (h.identityFile != null) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.key, size: 10, color: Color(0xFF5E5E5E)),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: Color(0xFF8E8E8E), fontSize: 11));
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.ctrl,
    this.obscure = false,
    this.hint,
    this.inputType,
  });

  final String label;
  final TextEditingController ctrl;
  final bool obscure;
  final String? hint;
  final TextInputType? inputType;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(label),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          keyboardType: inputType,
          style: const TextStyle(color: Color(0xFFC7C7C7), fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF4A4A4A)),
            filled: true,
            fillColor: const Color(0xFF1C1C1C),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 9),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFF3A3A3A))),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFF3A3A3A))),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFF2472C8))),
          ),
        ),
      ],
    );
  }
}

class _RadioOption extends StatelessWidget {
  const _RadioOption(
      {required this.label,
      required this.selected,
      required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? const Color(0xFF2472C8)
                  : const Color(0xFF5E5E5E),
              width: 2,
            ),
          ),
          child: selected
              ? Center(
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF2472C8),
                    ),
                  ),
                )
              : null,
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
              color: selected
                  ? const Color(0xFFC7C7C7)
                  : const Color(0xFF8E8E8E),
              fontSize: 13,
            )),
      ]),
    );
  }
}

// SSHSocket wrapper that disables Nagle's algorithm so each keypress is sent
// immediately instead of being held up to 40 ms by the OS write buffer.
class _NoDelaySocket implements SSHSocket {
  _NoDelaySocket._(this._socket);

  final Socket _socket;

  static Future<_NoDelaySocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.setOption(SocketOption.tcpNoDelay, true);
    return _NoDelaySocket._(s);
  }

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();
}
