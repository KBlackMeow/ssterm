import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// PowerShell prelude that makes the current process per-monitor DPI aware,
/// so WinForms dialogs (OpenFileDialog, etc.) render crisply on scaled Windows
/// displays instead of being bitmap-stretched (blurry) by the DWM.
const String windowsDpiAwarePrelude = r'''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SsTermDpi {
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  public static void Enable() {
    // -4 == DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (Windows 10 1703+).
    try { if (!SetProcessDpiAwarenessContext((IntPtr)(-4))) { SetProcessDPIAware(); } }
    catch { try { SetProcessDPIAware(); } catch {} }
  }
}
"@
[SsTermDpi]::Enable()
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
''';

/// Runs [script] via `powershell -EncodedCommand`, which sidesteps command-line
/// quoting issues for multi-line scripts. stdout is decoded as UTF-8 so that
/// non-ASCII paths (e.g. Chinese folder names) survive intact.
Future<ProcessResult> runPowerShellEncoded(String script) {
  final units = script.codeUnits; // UTF-16 code units
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes[i * 2] = units[i] & 0xFF; // little-endian (UTF-16LE)
    bytes[i * 2 + 1] = (units[i] >> 8) & 0xFF;
  }
  return Process.run(
    'powershell',
    ['-NoProfile', '-EncodedCommand', base64.encode(bytes)],
    stdoutEncoding: utf8,
  );
}
