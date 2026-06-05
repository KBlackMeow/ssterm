import 'dart:io';

import 'package:flutter/material.dart';

import '../models/port_forward_rule.dart';
import '../models/ssh_host.dart';
import '../services/file_picker_service.dart';
import '../widgets/frosted_glass.dart';
import 'ssh_host_builder.dart';

export '../models/connect_result.dart';

part 'connect_dialog_widgets.dart';

typedef _AuthMode = SshAuthMode;

/// Returns the [SshHost] profile to connect with, or `null` if the user
/// cancelled. On iOS/Android the form slides up as a bottom sheet; on other
/// platforms it appears as a centred glass dialog.
Future<SshHost?> showConnectDialog(
  BuildContext context, {
  SshHost? initialHost,
}) {
  final popupColor = AppColors.maybeOf(context)?.popup;
  if (Platform.isIOS || Platform.isAndroid) {
    return _showMobileConnectDialog(
      context,
      child: _ConnectDialog(initialHost: initialHost, mobileSheet: true, popupColor: popupColor),
    );
  }
  return showDialog<SshHost>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (_) => _ConnectDialog(initialHost: initialHost, popupColor: popupColor),
  );
}

Future<SshHost?> showEditHostDialog(
  BuildContext context, {
  SshHost? host,
}) {
  final popupColor = AppColors.maybeOf(context)?.popup;
  if (Platform.isIOS || Platform.isAndroid) {
    return _showMobileConnectDialog(
      context,
      child: _ConnectDialog(initialHost: host, editOnly: true, mobileSheet: true, popupColor: popupColor),
    );
  }
  return showDialog<SshHost>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (_) => _ConnectDialog(initialHost: host, editOnly: true, popupColor: popupColor),
  );
}

/// Mobile dialog via [showGeneralDialog] without a FadeTransition, so that
/// [BackdropFilter] inside [PopupSurface] blurs the actual screen content
/// instead of the route's own compositing layer.
Future<T?> _showMobileConnectDialog<T>(
  BuildContext context, {
  required Widget child,
}) {
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: false,
    barrierColor: const Color(0x66000000),
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, _, _) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460),
            child: child,
          ),
        ),
      );
    },
  );
}

// ─── Colors ─────────────────────────────────────────────────────────────────
const _kField = Color(0xFF141416);
const _kBorder = Color(0xFF282828);
const _kFocus = Color(0xFF2472C8);
const _kFg = Color(0xFFC7C7C7);
const _kLabel = Color(0xFF8E8E8E);
const _kError = Color(0xFFFF6E67);
const _kAccent = Color(0xFF2472C8);
const _kTitle = Color(0xFFD4D4D4);

// ─── Main dialog / sheet ─────────────────────────────────────────────────────
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({
    this.initialHost,
    this.editOnly = false,
    this.mobileSheet = false,
    this.popupColor,
  });

  final SshHost? initialHost;
  final bool editOnly;
  final bool mobileSheet;
  final Color? popupColor;

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
      user: _jumpUserCtrl.text.trim().isEmpty
          ? null
          : _jumpUserCtrl.text.trim(),
      password: _jumpAuthMode == _AuthMode.password
          ? (_jumpPasswordCtrl.text.trim().isEmpty
              ? null
              : _jumpPasswordCtrl.text.trim())
          : null,
      identityFile: _jumpAuthMode == _AuthMode.key
          ? (_jumpKeyCtrl.text.trim().isEmpty
              ? null
              : _jumpKeyCtrl.text.trim())
          : null,
    );
  }

  Future<void> _pickKey(TextEditingController ctrl) async {
    final path = await FilePickerService.pickFile();
    if (path != null) setState(() => ctrl.text = path);
  }

  void _submit() {
    final result = buildSshHostResult(
      hostText: _hostCtrl.text,
      userText: _userCtrl.text,
      portText: _portCtrl.text,
      aliasText: _nameCtrl.text,
      authMode: _authMode,
      passwordText: _passwordCtrl.text,
      existingPassword: widget.initialHost?.password,
      keyText: _keyCtrl.text,
      forwardRules: _forwardRules,
      jumpHost: _buildJumpHost(),
      keepaliveInterval: _keepaliveInterval,
      autoReconnect: _autoReconnect,
      sessionLog: _sessionLog,
    );
    switch (result) {
      case SshHostFormError(:final message):
        setState(() => _error = message);
      case SshHostFormSuccess(:final host):
        Navigator.of(context).pop(host);
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.mobileSheet
        ? _buildMobileSheet(context)
        : _buildDesktopDialog(context);
  }

  // ── Desktop: glass dialog ──────────────────────────────────────────────────

  // Only apply popup colour when it is dark enough that the form's internal
  // dark-coloured elements (_kField, _kBorder, etc.) remain readable.
  Color get _dialogFill {
    final p = widget.popupColor;
    if (p != null && p.computeLuminance() < 0.5) return p;
    return FrostedGlassStyle.menuFillFrosted;
  }

  Widget _buildDesktopDialog(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 420,
        child: PopupSurface(
          color: _dialogFill,
          backdropBlur: 20,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _buildScrollable(),
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
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _buildFormFields(titleFontSize: 15),
          ),
        ),
      ),
    );
  }

  // ── Mobile: full-height bottom sheet ──────────────────────────────────────

  Widget _buildMobileSheet(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final title = widget.editOnly
        ? (widget.initialHost != null ? 'Edit Connection' : 'Add Connection')
        : 'New Connection';

    final screenH = MediaQuery.of(context).size.height;
    return PopupSurface(
      color: _dialogFill,
      backdropBlur: 24,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Sheet header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _kTitle,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: const Color(0xFF252525),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: _kLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF252525)),
          // Scrollable form — explicit max height so dialog sizes to content
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: screenH * 0.74),
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(
                  20,
                  16,
                  20,
                  viewInsets.bottom + 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildFormFields(titleFontSize: 0),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared form fields ─────────────────────────────────────────────────────

  /// Returns the form field widgets. [titleFontSize] > 0 prepends the title
  /// text (desktop dialog); pass 0 to omit it (mobile sheet has its own header).
  List<Widget> _buildFormFields({required double titleFontSize}) {
    return [
      if (titleFontSize > 0) ...[
        Text(
          widget.editOnly
              ? (widget.initialHost != null
                  ? 'Edit SSH Config'
                  : 'Add SSH Config')
              : 'New SSH',
          style: TextStyle(
            color: _kTitle,
            fontSize: titleFontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 20),
      ],

      // ── Basic ──────────────────────────────────────────────────────────────
      _Field(
        label: 'Name',
        ctrl: _nameCtrl,
        hint: 'Leave empty to use IP:port',
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(child: _Field(label: 'IP / Hostname', ctrl: _hostCtrl)),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: _Field(
              label: 'Port',
              ctrl: _portCtrl,
              inputType: TextInputType.number,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      _Field(label: 'Username *', ctrl: _userCtrl, hint: 'Required'),
      const SizedBox(height: 10),
      _buildAuthToggle(_authMode, (m) => setState(() => _authMode = m)),
      const SizedBox(height: 10),
      if (_authMode == _AuthMode.password)
        _Field(
          label: 'Password',
          ctrl: _passwordCtrl,
          hint: 'Leave empty to use ~/.ssh default key',
          obscure: true,
        )
      else
        _Field(
          label: 'Identity file',
          ctrl: _keyCtrl,
          hint: 'e.g. ~/.ssh/id_ed25519',
          onBrowse: widget.mobileSheet ? () => _pickKey(_keyCtrl) : null,
        ),

      const SizedBox(height: 16),

      // ── Jump Host ──────────────────────────────────────────────────────────
      _Section(
        title: 'Jump Host (ProxyJump)',
        enabled: _jumpEnabled,
        onToggle: (v) => setState(() => _jumpEnabled = v),
        child: _buildJumpFields(),
      ),

      const SizedBox(height: 8),

      // ── Port Forwarding ────────────────────────────────────────────────────
      _ForwardSection(
        rules: _forwardRules,
        onChanged: () => setState(() {}),
      ),

      const SizedBox(height: 8),

      // ── Advanced ───────────────────────────────────────────────────────────
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
        onPressed: _submit,
        style: ElevatedButton.styleFrom(
          backgroundColor: _kAccent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 13),
        ),
        child: Text(widget.editOnly ? 'Save' : 'Connect'),
      ),
    ];
  }

  Widget _buildJumpFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Field(label: 'IP / Hostname', ctrl: _jumpHostCtrl),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 72,
              child: _Field(
                label: 'Port',
                ctrl: _jumpPortCtrl,
                inputType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _Field(label: 'Username', ctrl: _jumpUserCtrl),
        const SizedBox(height: 8),
        _buildAuthToggle(
          _jumpAuthMode,
          (m) => setState(() => _jumpAuthMode = m),
        ),
        const SizedBox(height: 8),
        if (_jumpAuthMode == _AuthMode.password)
          _Field(label: 'Password', ctrl: _jumpPasswordCtrl, obscure: true)
        else
          _Field(
            label: 'Identity file',
            ctrl: _jumpKeyCtrl,
            onBrowse: widget.mobileSheet ? () => _pickKey(_jumpKeyCtrl) : null,
          ),
      ],
    );
  }

  Widget _buildAuthToggle(
    _AuthMode current,
    ValueChanged<_AuthMode> onChanged,
  ) {
    return SegmentedButton<_AuthMode>(
      segments: const [
        ButtonSegment(
          value: _AuthMode.password,
          label: Text('Password', style: TextStyle(fontSize: 12)),
        ),
        ButtonSegment(
          value: _AuthMode.key,
          label: Text('Key file', style: TextStyle(fontSize: 12)),
        ),
      ],
      selected: {current},
      onSelectionChanged: (s) => onChanged(s.first),
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
