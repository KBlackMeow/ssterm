import 'package:flutter/material.dart';

import '../models/ssh_host.dart';

typedef PasswordPromptResult = ({String password, bool save});

Future<PasswordPromptResult?> showPasswordPromptDialog(
  BuildContext context,
  SshHost host,
) {
  return showDialog<PasswordPromptResult>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0x66000000),
    builder: (_) => _PasswordPromptDialog(host: host),
  );
}

const _kBg     = Color(0xFF252525);
const _kField  = Color(0xFF141416);
const _kBorder = Color(0xFF282828);
const _kFocus  = Color(0xFF2472C8);
const _kFg     = Color(0xFFC7C7C7);
const _kLabel  = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);
const _kTitle  = Color(0xFFD4D4D4);

class _PasswordPromptDialog extends StatefulWidget {
  const _PasswordPromptDialog({required this.host});
  final SshHost host;

  @override
  State<_PasswordPromptDialog> createState() => _PasswordPromptDialogState();
}

class _PasswordPromptDialogState extends State<_PasswordPromptDialog> {
  final _ctrl = TextEditingController();
  bool _obscure = true;
  bool _save = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    Navigator.of(context).pop((password: _ctrl.text, save: _save));
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = '${widget.host.user ?? ''}@${widget.host.hostname}'
        '${widget.host.port != 22 ? ':${widget.host.port}' : ''}';

    return Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 340,
        child: Material(
          color: _kBg,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Password required',
                  style: const TextStyle(
                    color: _kTitle,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(color: _kLabel, fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _ctrl,
                  obscureText: _obscure,
                  autofocus: true,
                  onSubmitted: (_) => _confirm(),
                  style: const TextStyle(color: _kFg, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle: const TextStyle(color: _kLabel, fontSize: 11),
                    filled: true,
                    fillColor: _kField,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
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
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        size: 16,
                        color: _kLabel,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => setState(() => _save = !_save),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          height: 20,
                          child: Switch(
                            value: _save,
                            onChanged: (v) => setState(() => _save = v),
                            activeThumbColor: _kAccent,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Save password',
                          style: TextStyle(color: _kFg, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: _kLabel),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _confirm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                      ),
                      child: const Text('Connect'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
