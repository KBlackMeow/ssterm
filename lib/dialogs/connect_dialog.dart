import 'package:flutter/material.dart';

import '../models/connect_result.dart';
import '../models/ssh_host.dart';
import '../services/host_key_verifier.dart';
import '../services/ssh_connection.dart';

export '../models/connect_result.dart';

enum _AuthMode { password, key }

Future<ConnectResult?> showConnectDialog(
  BuildContext context, {
  SshHost? initialHost,
}) {
  return showDialog<ConnectResult>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => _ConnectDialog(initialHost: initialHost),
  );
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({this.initialHost});

  final SshHost? initialHost;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final _nameCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();

  _AuthMode _authMode = _AuthMode.password;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final h = widget.initialHost;
    if (h != null) _applyHost(h);
  }

  void _applyHost(SshHost h) {
    _nameCtrl.text = h.alias;
    _hostCtrl.text = h.hostname;
    _portCtrl.text = h.port.toString();
    _userCtrl.text = h.user ?? '';
    if (h.usesIdentityFile) {
      _authMode = _AuthMode.key;
      _keyCtrl.text = h.identityFile!;
      _passwordCtrl.clear();
    } else if (h.usesPassword) {
      _authMode = _AuthMode.password;
      _passwordCtrl.text = h.password!;
      _keyCtrl.clear();
    } else if (h.identityFile != null && h.identityFile!.isNotEmpty) {
      _authMode = _AuthMode.key;
      _keyCtrl.text = h.identityFile!;
    } else {
      _authMode = _AuthMode.password;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final host = _hostCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;

    if (host.isEmpty) {
      setState(() => _error = '请输入 IP 或主机名');
      return;
    }
    if (user.isEmpty) {
      setState(() => _error = '用户名为必填项');
      return;
    }
    if (port < 1 || port > 65535) {
      setState(() => _error = '端口无效（1–65535）');
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      final result = await connectSshParams(
        hostname: host,
        port: port,
        username: user,
        alias: _nameCtrl.text,
        password:
            _authMode == _AuthMode.password ? _passwordCtrl.text : null,
        identityFile: _authMode == _AuthMode.key ? _keyCtrl.text : null,
        verifyHostKey: createHostKeyVerifier(
          context,
          hostname: host,
          port: port,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = _friendlyError(e);
        });
      }
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('userauth') ||
        s.contains('authentication') ||
        s.contains('permission')) {
      return '认证失败，请检查密码或密钥';
    }
    if (s.contains('refused')) return '连接被拒绝，请检查 IP 和端口';
    if (s.contains('timeout') || s.contains('timedout')) {
      return '连接超时';
    }
    if (s.contains('hostkey') || s.contains('host key')) {
      return '主机密钥验证失败';
    }
    if (s.contains('nodename') || s.contains('socketexception')) {
      return '无法解析主机';
    }
    return e.toString().replaceAll('Exception: ', '').replaceAll('Error: ', '');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Stack(
            children: [
              _buildForm(),
              if (_connecting)
                Positioned.fill(
                  child: Container(
                    color: const Color(0xCC2B2B2B),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: Color(0xFF2472C8),
                            strokeWidth: 2,
                          ),
                          SizedBox(height: 16),
                          Text(
                            '连接中…',
                            style: TextStyle(
                              color: Color(0xFF8E8E8E),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '新建 SSH',
          style: TextStyle(
            color: Color(0xFFD4D4D4),
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 20),
        _Field(
          label: '主机名称',
          ctrl: _nameCtrl,
          hint: '留空则使用 IP:端口',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _Field(label: 'IP', ctrl: _hostCtrl)),
            const SizedBox(width: 8),
            SizedBox(
              width: 72,
              child: _Field(
                label: '端口',
                ctrl: _portCtrl,
                inputType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Field(label: '用户名 *', ctrl: _userCtrl, hint: '必填'),
        const SizedBox(height: 10),
        _buildAuthToggle(),
        const SizedBox(height: 10),
        if (_authMode == _AuthMode.password)
          _Field(
            label: '密码',
            ctrl: _passwordCtrl,
            hint: '留空则尝试 ~/.ssh 默认密钥',
            obscure: true,
          )
        else
          _Field(
            label: '私钥路径',
            ctrl: _keyCtrl,
            hint: '例如 ~/.ssh/id_ed25519',
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: const TextStyle(color: Color(0xFFFF6E67), fontSize: 12)),
        ],
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _connecting ? null : _create,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2472C8),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: const Text('创建'),
        ),
      ],
    );
  }

  Widget _buildAuthToggle() {
    return SegmentedButton<_AuthMode>(
      segments: const [
        ButtonSegment(
          value: _AuthMode.password,
          label: Text('密码', style: TextStyle(fontSize: 12)),
        ),
        ButtonSegment(
          value: _AuthMode.key,
          label: Text('密钥', style: TextStyle(fontSize: 12)),
        ),
      ],
      selected: {_authMode},
      onSelectionChanged:
          _connecting ? null : (s) => setState(() => _authMode = s.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return const Color(0xFF8E8E8E);
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const Color(0xFF2472C8);
          }
          return const Color(0xFF1C1C1C);
        }),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.ctrl,
    this.hint,
    this.obscure = false,
    this.inputType,
  });

  final String label;
  final TextEditingController ctrl;
  final String? hint;
  final bool obscure;
  final TextInputType? inputType;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Color(0xFF8E8E8E), fontSize: 11)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          keyboardType: inputType,
          style: const TextStyle(color: Color(0xFFC7C7C7), fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF4A4A4A), fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF1C1C1C),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: Color(0xFF3A3A3A)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: Color(0xFF3A3A3A)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: Color(0xFF2472C8)),
            ),
          ),
        ),
      ],
    );
  }
}
