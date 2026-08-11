import 'dart:io';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PTY startup context identifies launch without exposing arguments', () {
    final context = formatPtyStartContext(
      executable: r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      arguments: const ['-NoLogo', '-EncodedCommand', 'SECRET_BASE64_PAYLOAD'],
      workingDirectory: r'C:\Users\illya',
    );

    expect(context, contains('executable='));
    expect(context, contains(r'C:\Windows\System32'));
    expect(context, contains(r'cwd=C:\Users\illya'));
    expect(context, contains('argumentCount=3'));
    expect(context, contains('argumentLengths=[7, 15, 21]'));
    expect(context, isNot(contains('-EncodedCommand')));
    expect(context, isNot(contains('SECRET_BASE64_PAYLOAD')));
  });

  test(
    'Windows native source preserves detailed errors across isolate boundary',
    () {
      final dartSource = File(
        'packages/flutter_pty/lib/flutter_pty.dart',
      ).readAsStringSync();
      final nativeSource = File(
        'packages/flutter_pty/src/flutter_pty_win.c',
      ).readAsStringSync();

      expect(dartSource, contains('error: _getPtyError()'));
      expect(dartSource, contains('nativeResult.error'));
      expect(nativeSource, contains('FormatMessageW'));
      expect(nativeSource, contains('__declspec(thread)'));
      expect(nativeSource, contains('HRESULT 0x%08lX'));
      expect(nativeSource, contains('HRESULT_CODE(result)'));
      expect(nativeSource, contains('CreateProcessW'));
      expect(nativeSource, isNot(contains('printf("error no:')));
    },
  );
}
