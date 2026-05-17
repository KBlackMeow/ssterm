import 'package:flutter/material.dart';

import '../models/connect_result.dart';
import '../models/port_forward_rule.dart';
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

// ─── Colors ─────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF2B2B2B);
const _kField = Color(0xFF1C1C1C);
const _kBorder = Color(0xFF3A3A3A);
const _kFocus = Color(0xFF2472C8);
const _kFg = Color(0xFFC7C7C7);
const _kLabel = Color(0xFF8E8E8E);
const _kError = Color(0xFFFF6E67);
const _kAccent = Color(0xFF2472C8);
const _kTitle = Color(0xFFD4D4D4);

// ─── Main dialog ─────────────────────────────────────────────────────────────
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({this.initialHost});
  final SshHost? initialHost;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  // Basic
  final _nameCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  _AuthMode _authMode = _AuthMode.password;

  // Jump host
  bool _jumpEnabled = false;
  final _jumpHostCtrl = TextEditingController();
  final _jumpPortCtrl = TextEditingController(text: '22');
  final _jumpUserCtrl = TextEditingController();
  final _jumpPasswordCtrl = TextEditingController();
  final _jumpKeyCtrl = TextEditingController();
  _AuthMode _jumpAuthMode = _AuthMode.password;

  // Port forwarding
  final List<PortForwardRule> _forwardRules = [];

  // Advanced
  int _keepaliveInterval = 0;
  bool _autoReconnect = false;
  bool _sessionLog = false;

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
    } else if (h.usesPassword) {
      _authMode = _AuthMode.password;
      _passwordCtrl.text = h.password!;
    } else {
      _authMode = _AuthMode.password;
    }

    _forwardRules
      ..clear()
      ..addAll(h.forwardRules);

    if (h.jumpHost != null) {
      _jumpEnabled = true;
      final j = h.jumpHost!;
      _jumpHostCtrl.text = j.hostname;
      _jumpPortCtrl.text = j.port.toString();
      _jumpUserCtrl.text = j.user ?? '';
      if (j.usesIdentityFile) {
        _jumpAuthMode = _AuthMode.key;
        _jumpKeyCtrl.text = j.identityFile!;
      } else if (j.usesPassword) {
        _jumpAuthMode = _AuthMode.password;
        _jumpPasswordCtrl.text = j.password!;
      }
    }

    _keepaliveInterval = h.keepaliveInterval;
    _autoReconnect = h.autoReconnect;
    _sessionLog = h.sessionLog;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    _keyCtrl.dispose();
    _jumpHostCtrl.dispose();
    _jumpPortCtrl.dispose();
    _jumpUserCtrl.dispose();
    _jumpPasswordCtrl.dispose();
    _jumpKeyCtrl.dispose();
    super.dispose();
  }

  SshHost? _buildJumpHost() {
    if (!_jumpEnabled) return null;
    final jh = _jumpHostCtrl.text.trim();
    if (jh.isEmpty) return null;
    return SshHost(
      alias: jh,
      hostname: jh,
      port: int.tryParse(_jumpPortCtrl.text.trim()) ?? 22,
      user: _jumpUserCtrl.text.trim().isEmpty ? null : _jumpUserCtrl.text.trim(),
      password: _jumpAuthMode == _AuthMode.password
          ? (_jumpPasswordCtrl.text.trim().isEmpty
              ? null
              : _jumpPasswordCtrl.text.trim())
          : null,
      identityFile: _jumpAuthMode == _AuthMode.key
          ? (_jumpKeyCtrl.text.trim().isEmpty ? null : _jumpKeyCtrl.text.trim())
          : null,
    );
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
      final jumpHost = _buildJumpHost();
      final result = await connectSshParams(
        hostname: host,
        port: port,
        username: user,
        alias: _nameCtrl.text,
        password: _authMode == _AuthMode.password ? _passwordCtrl.text : null,
        identityFile: _authMode == _AuthMode.key ? _keyCtrl.text : null,
        jumpHost: jumpHost,
        keepaliveInterval: _keepaliveInterval,
        autoReconnect: _autoReconnect,
        sessionLog: _sessionLog,
        verifyHostKey: createHostKeyVerifier(
          context,
          hostname: host,
          port: port,
        ),
        jumpVerifyHostKey: jumpHost != null
            ? createHostKeyVerifier(
                context,
                hostname: jumpHost.hostname,
                port: jumpHost.port,
              )
            : null,
      );

      // Attach forward rules to the profile stored in ConnectResult
      final profileWithRules = result.profile.copyWith(
        forwardRules: List.of(_forwardRules),
      );

      if (!mounted) return;
      Navigator.of(context).pop(
        ConnectResult(
          client: result.client,
          jumpClient: result.jumpClient,
          session: result.session,
          sftp: result.sftp,
          host: result.host,
          username: result.username,
          alias: result.alias,
          profile: profileWithRules,
          mode: result.mode,
        ),
      );
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
    if (s.contains('timeout') || s.contains('timedout')) return '连接超时';
    if (s.contains('hostkey') || s.contains('host key')) return '主机密钥验证失败';
    if (s.contains('nodename') || s.contains('socketexception')) {
      return '无法解析主机';
    }
    return e.toString().replaceAll('Exception: ', '').replaceAll('Error: ', '');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _kBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Stack(
            children: [
              _buildScrollable(),
              if (_connecting)
                Positioned.fill(
                  child: Container(
                    color: const Color(0xCC2B2B2B),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: _kAccent,
                            strokeWidth: 2,
                          ),
                          SizedBox(height: 16),
                          Text(
                            '连接中…',
                            style: TextStyle(color: _kLabel, fontSize: 13),
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

  Widget _buildScrollable() {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '新建 SSH',
              style: TextStyle(
                color: _kTitle,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),

            // ── Basic ──────────────────────────────────────────────────────
            _Field(label: '主机名称', ctrl: _nameCtrl, hint: '留空则使用 IP:端口'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _Field(label: 'IP / 主机名', ctrl: _hostCtrl)),
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
            _buildAuthToggle(_authMode, (m) => setState(() => _authMode = m)),
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

            const SizedBox(height: 16),

            // ── Jump Host ─────────────────────────────────────────────────
            _Section(
              title: '跳板机 (ProxyJump)',
              enabled: _jumpEnabled,
              onToggle: (v) => setState(() => _jumpEnabled = v),
              child: _buildJumpFields(),
            ),

            const SizedBox(height: 8),

            // ── Port Forwarding ───────────────────────────────────────────
            _ForwardSection(
              rules: _forwardRules,
              onChanged: () => setState(() {}),
            ),

            const SizedBox(height: 8),

            // ── Advanced ─────────────────────────────────────────────────
            _AdvancedSection(
              keepaliveInterval: _keepaliveInterval,
              autoReconnect: _autoReconnect,
              sessionLog: _sessionLog,
              onKeepaliveChanged: (v) => setState(() => _keepaliveInterval = v),
              onAutoReconnectChanged: (v) => setState(() => _autoReconnect = v),
              onSessionLogChanged: (v) => setState(() => _sessionLog = v),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: _kError, fontSize: 12),
              ),
            ],

            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _connecting ? null : _create,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJumpFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Field(label: 'IP / 主机名', ctrl: _jumpHostCtrl),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 72,
              child: _Field(
                label: '端口',
                ctrl: _jumpPortCtrl,
                inputType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _Field(label: '用户名', ctrl: _jumpUserCtrl),
        const SizedBox(height: 8),
        _buildAuthToggle(
          _jumpAuthMode,
          (m) => setState(() => _jumpAuthMode = m),
        ),
        const SizedBox(height: 8),
        if (_jumpAuthMode == _AuthMode.password)
          _Field(label: '密码', ctrl: _jumpPasswordCtrl, obscure: true)
        else
          _Field(label: '私钥路径', ctrl: _jumpKeyCtrl),
      ],
    );
  }

  Widget _buildAuthToggle(_AuthMode current, ValueChanged<_AuthMode> onChanged) {
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
      selected: {current},
      onSelectionChanged:
          _connecting ? null : (s) => onChanged(s.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return _kLabel;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return _kAccent;
          return _kField;
        }),
      ),
    );
  }
}

// ─── Section wrapper (collapsible with enable toggle) ────────────────────────
class _Section extends StatefulWidget {
  const _Section({
    required this.title,
    required this.enabled,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final Widget child;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  bool _expanded = false;

  @override
  void didUpdateWidget(_Section old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !old.enabled) _expanded = true;
    if (!widget.enabled && old.enabled) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            onTap: widget.enabled
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Switch(
                    value: widget.enabled,
                    onChanged: widget.onToggle,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    activeThumbColor: _kAccent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(color: _kFg, fontSize: 12),
                    ),
                  ),
                  if (widget.enabled)
                    Icon(
                      _expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 16,
                      color: _kLabel,
                    ),
                ],
              ),
            ),
          ),
          if (widget.enabled && _expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

// ─── Port forwarding section ─────────────────────────────────────────────────
class _ForwardSection extends StatefulWidget {
  const _ForwardSection({
    required this.rules,
    required this.onChanged,
  });

  final List<PortForwardRule> rules;
  final VoidCallback onChanged;

  @override
  State<_ForwardSection> createState() => _ForwardSectionState();
}

class _ForwardSectionState extends State<_ForwardSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final count = widget.rules.length;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.swap_horiz,
                    size: 14,
                    color: _kLabel,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      count == 0
                          ? '端口转发'
                          : '端口转发 ($count 条规则)',
                      style: const TextStyle(color: _kFg, fontSize: 12),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: _kLabel,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _buildRuleList(),
            ),
        ],
      ),
    );
  }

  Widget _buildRuleList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.rules.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '暂无规则',
              style: TextStyle(color: _kLabel, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          )
        else
          for (var i = 0; i < widget.rules.length; i++)
            _RuleRow(
              rule: widget.rules[i],
              onDelete: () {
                setState(() => widget.rules.removeAt(i));
                widget.onChanged();
              },
              onToggle: (v) {
                setState(() {
                  widget.rules[i] = widget.rules[i].copyWith(enabled: v);
                });
                widget.onChanged();
              },
            ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _addRule,
          icon: const Icon(Icons.add, size: 13),
          label: const Text('添加规则', style: TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kLabel,
            side: const BorderSide(color: _kBorder),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }

  void _addRule() async {
    final rule = await showDialog<PortForwardRule>(
      context: context,
      builder: (ctx) => const _AddRuleDialog(),
    );
    if (rule != null) {
      setState(() => widget.rules.add(rule));
      widget.onChanged();
    }
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.rule,
    required this.onDelete,
    required this.onToggle,
  });

  final PortForwardRule rule;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Switch(
            value: rule.enabled,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            activeThumbColor: _kAccent,
          ),
          Expanded(
            child: Text(
              rule.label,
              style: TextStyle(
                color: rule.enabled ? _kFg : _kLabel,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            color: _kLabel,
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            tooltip: '删除',
          ),
        ],
      ),
    );
  }
}

class _AddRuleDialog extends StatefulWidget {
  const _AddRuleDialog();

  @override
  State<_AddRuleDialog> createState() => _AddRuleDialogState();
}

class _AddRuleDialogState extends State<_AddRuleDialog> {
  ForwardType _type = ForwardType.local;
  final _localPortCtrl = TextEditingController();
  final _remoteHostCtrl = TextEditingController();
  final _remotePortCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _localPortCtrl.dispose();
    _remoteHostCtrl.dispose();
    _remotePortCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final lp = int.tryParse(_localPortCtrl.text.trim()) ?? 0;
    if (lp < 1 || lp > 65535) {
      setState(() => _error = '本地端口无效');
      return;
    }
    if (_type == ForwardType.local) {
      if (_remoteHostCtrl.text.trim().isEmpty) {
        setState(() => _error = '请输入远端主机');
        return;
      }
      final rp = int.tryParse(_remotePortCtrl.text.trim()) ?? 0;
      if (rp < 1 || rp > 65535) {
        setState(() => _error = '远端端口无效');
        return;
      }
    }
    if (_type == ForwardType.remote) {
      final rp = int.tryParse(_remotePortCtrl.text.trim()) ?? 0;
      if (rp < 1 || rp > 65535) {
        setState(() => _error = '服务器端口无效');
        return;
      }
    }

    Navigator.of(context).pop(
      PortForwardRule(
        type: _type,
        localPort: lp,
        remoteHost: _remoteHostCtrl.text.trim(),
        remotePort: int.tryParse(_remotePortCtrl.text.trim()) ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _kBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: 360,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '添加转发规则',
                style: TextStyle(color: _kTitle, fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              // Type selector
              DropdownButtonFormField<ForwardType>(
                // ignore: deprecated_member_use
                value: _type,
                dropdownColor: _kBg,
                style: const TextStyle(color: _kFg, fontSize: 13),
                decoration: _inputDecoration('类型'),
                items: const [
                  DropdownMenuItem(
                    value: ForwardType.local,
                    child: Text('L — 本地转发',
                        overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: ForwardType.remote,
                    child: Text('R — 远端转发',
                        overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: ForwardType.dynamic_,
                    child: Text('D — 动态 SOCKS5',
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
                onChanged: (v) => setState(() => _type = v!),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  switch (_type) {
                    ForwardType.local =>
                      'localhost:本地端口  →  服务器  →  远端主机:端口',
                    ForwardType.remote =>
                      '服务器监听端口  →  SSH隧道  →  localhost:本地端口',
                    ForwardType.dynamic_ =>
                      'SOCKS5 代理，所有流量经服务器出口',
                  },
                  style: const TextStyle(
                      color: Color(0xFF6E6E6E), fontSize: 11),
                ),
              ),
              const SizedBox(height: 6),
              _Field(
                label: _type == ForwardType.dynamic_
                    ? '本地 SOCKS5 端口'
                    : '本地端口',
                ctrl: _localPortCtrl,
                inputType: TextInputType.number,
              ),
              if (_type == ForwardType.local) ...[
                const SizedBox(height: 10),
                _Field(
                  label: '远端主机',
                  ctrl: _remoteHostCtrl,
                  hint: '例如 localhost 或 db.internal',
                ),
                const SizedBox(height: 10),
                _Field(
                  label: '远端端口',
                  ctrl: _remotePortCtrl,
                  inputType: TextInputType.number,
                ),
              ],
              if (_type == ForwardType.remote) ...[
                const SizedBox(height: 10),
                _Field(
                  label: '服务器监听端口',
                  ctrl: _remotePortCtrl,
                  inputType: TextInputType.number,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: _kError, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消', style: TextStyle(color: _kLabel)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _confirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kAccent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Advanced section ─────────────────────────────────────────────────────────
class _AdvancedSection extends StatefulWidget {
  const _AdvancedSection({
    required this.keepaliveInterval,
    required this.autoReconnect,
    required this.sessionLog,
    required this.onKeepaliveChanged,
    required this.onAutoReconnectChanged,
    required this.onSessionLogChanged,
  });

  final int keepaliveInterval;
  final bool autoReconnect;
  final bool sessionLog;
  final ValueChanged<int> onKeepaliveChanged;
  final ValueChanged<bool> onAutoReconnectChanged;
  final ValueChanged<bool> onSessionLogChanged;

  @override
  State<_AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<_AdvancedSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.tune, size: 14, color: _kLabel),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '高级',
                      style: TextStyle(color: _kFg, fontSize: 12),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: _kLabel,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Keepalive
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Keepalive 间隔',
                          style: TextStyle(color: _kLabel, fontSize: 12),
                        ),
                      ),
                      DropdownButton<int>(
                        value: widget.keepaliveInterval,
                        dropdownColor: _kBg,
                        style: const TextStyle(color: _kFg, fontSize: 12),
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('禁用')),
                          DropdownMenuItem(value: 15, child: Text('15 秒')),
                          DropdownMenuItem(value: 30, child: Text('30 秒')),
                          DropdownMenuItem(value: 60, child: Text('60 秒')),
                        ],
                        onChanged: (v) => widget.onKeepaliveChanged(v ?? 0),
                      ),
                    ],
                  ),
                  // Auto-reconnect
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '断线自动重连',
                          style: TextStyle(color: _kLabel, fontSize: 12),
                        ),
                      ),
                      Switch(
                        value: widget.autoReconnect,
                        onChanged: widget.onAutoReconnectChanged,
                        activeThumbColor: _kAccent,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                  // Session log
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '会话日志',
                          style: TextStyle(color: _kLabel, fontSize: 12),
                        ),
                      ),
                      Switch(
                        value: widget.sessionLog,
                        onChanged: widget.onSessionLogChanged,
                        activeThumbColor: _kAccent,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                  if (widget.sessionLog)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '日志保存至 ~/.ssterm/logs/',
                        style: const TextStyle(
                          color: _kLabel,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Shared input widgets ────────────────────────────────────────────────────
InputDecoration _inputDecoration(String label) => InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _kLabel, fontSize: 11),
      filled: true,
      fillColor: _kField,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: _kBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: _kBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: _kFocus),
      ),
    );

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
        Text(label, style: const TextStyle(color: _kLabel, fontSize: 11)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          keyboardType: inputType,
          style: const TextStyle(color: _kFg, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF4A4A4A), fontSize: 12),
            filled: true,
            fillColor: _kField,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: _kBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: _kBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: _kFocus),
            ),
          ),
        ),
      ],
    );
  }
}
