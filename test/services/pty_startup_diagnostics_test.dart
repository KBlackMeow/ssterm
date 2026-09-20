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

  test('Unix PTY defaults to the Rust core with an explicit C fallback', () {
    final nativeSource = File(
      'packages/flutter_pty/src/flutter_pty_unix.c',
    ).readAsStringSync();

    expect(nativeSource, contains('ssterm_pty_create_with_environment'));
    expect(nativeSource, contains('SSTERM_USE_RUST_PTY=0'));
    expect(nativeSource, contains('strcmp(enabled, "0") == 0'));
    expect(nativeSource, contains('libssterm_pty_core'));
    expect(nativeSource, contains('handle->ackRead = options->ackRead'));
    expect(nativeSource, contains('pthread_cond_wait'));
    expect(nativeSource, isNot(contains('handle->ackRead = false')));
  });

  test('Windows PTY defaults to the Rust ConPTY bridge with bounded reads', () {
    final nativeSource = File(
      'packages/flutter_pty/src/flutter_pty_win.c',
    ).readAsStringSync();

    expect(nativeSource, contains('ssterm_pty_core.dll'));
    expect(nativeSource, contains('ssterm_pty_create_with_environment'));
    expect(nativeSource, contains('SSTERM_USE_RUST_PTY'));
    expect(nativeSource, contains('#define PTY_READ_BUFFER_SIZE (128 * 1024)'));
    expect(nativeSource, contains('#define PTY_RUST_READ_WINDOW 32'));
    expect(nativeSource, contains('char buffer[PTY_READ_BUFFER_SIZE]'));
    expect(
      nativeSource,
      contains('handle->rust_read_credits = PTY_RUST_READ_WINDOW'),
    );
    expect(nativeSource, contains('WakeConditionVariable'));
    // The Rust core opens ConPTY without PSEUDOCONSOLE_INHERIT_CURSOR, so the
    // bridge must not inject a synthetic cursor-position reply at startup.
    expect(nativeSource, isNot(contains('1;1R')));
    expect(nativeSource, contains('wsl.exe'));
  });

  test(
    'Windows Rust core answers the sidecar DA1 query and ships the host',
    () {
      final rustSource = File(
        'native/pty_core/src/windows.rs',
      ).readAsStringSync();

      // A sidecar OpenConsole opens with CSI c (DA1) and stalls the session
      // for ~3 s when nothing answers; the core must reply and consume the
      // query so the Dart terminal never answers it a second time.
      expect(rustSource, contains('answer_startup_query'));
      expect(rustSource, contains(r'b"\x1b[c"'));
      expect(rustSource, contains('copy_within(3..count, 0)'));

      final cmakeSource = File('windows/CMakeLists.txt').readAsStringSync();
      expect(cmakeSource, contains('conpty/x64/conpty.dll'));
      expect(cmakeSource, contains('conpty/x64/OpenConsole.exe'));

      expect(
        File('windows/conpty/x64/conpty.dll').existsSync(),
        isTrue,
        reason: 'the vendored ConPTY sidecar must stay in the repository',
      );
      expect(File('windows/conpty/x64/OpenConsole.exe').existsSync(), isTrue);
    },
  );

  test('Windows Rust PTY interrupts reads before joining teardown threads', () {
    final nativeSource = File(
      'packages/flutter_pty/src/flutter_pty_win.c',
    ).readAsStringSync();
    final rustSource = File(
      'native/pty_core/src/windows.rs',
    ).readAsStringSync();

    final destroyStart = nativeSource.indexOf(
      'FFI_PLUGIN_EXPORT void pty_destroy(PtyHandle *handle)',
    );
    final destroyEnd = nativeSource.indexOf(
      'FFI_PLUGIN_EXPORT void pty_write',
      destroyStart,
    );
    final destroy = nativeSource.substring(destroyStart, destroyEnd);
    expect(destroy, contains('rust_pty_api.interrupt(handle->rust_pty)'));
    expect(destroy, contains('CancelSynchronousIo(handle->rust_read_thread)'));
    expect(destroy, contains('CreateThread(NULL, 0, destroy_rust_pty_thread'));
    expect(destroy, isNot(contains('WaitForSingleObject(')));

    expect(rustSource, contains('CancelIoEx(read_handle'));
    expect(rustSource, contains('ssterm-conpty-close'));
    expect(rustSource, contains('.take()'));
  });

  test('Unix Rust PTY teardown never joins bridge threads on the caller', () {
    final nativeSource = File(
      'packages/flutter_pty/src/flutter_pty_unix.c',
    ).readAsStringSync();

    final destroyWorkerStart = nativeSource.indexOf(
      'static void *destroy_rust_pty(void *arg)',
    );
    final publicDestroyStart = nativeSource.indexOf(
      'FFI_PLUGIN_EXPORT void pty_destroy(PtyHandle *handle)',
    );
    final publicDestroyEnd = nativeSource.indexOf(
      'FFI_PLUGIN_EXPORT void pty_write',
      publicDestroyStart,
    );

    expect(destroyWorkerStart, greaterThanOrEqualTo(0));
    expect(publicDestroyStart, greaterThan(destroyWorkerStart));
    expect(publicDestroyEnd, greaterThan(publicDestroyStart));

    final worker = nativeSource.substring(
      destroyWorkerStart,
      publicDestroyStart,
    );
    final caller = nativeSource.substring(publicDestroyStart, publicDestroyEnd);
    expect(worker, contains('pthread_join(handle->rust_read_thread'));
    expect(worker, contains('pthread_join(handle->rust_wait_thread'));
    expect(caller, contains('pthread_create(&destroy_thread'));
    expect(caller, contains('pthread_detach(destroy_thread)'));
    expect(caller, isNot(contains('pthread_join(')));
  });

  test('Unix PTY uses a bounded asynchronous ACK window', () {
    final nativeSource = File(
      'packages/flutter_pty/src/flutter_pty_unix.c',
    ).readAsStringSync();

    expect(nativeSource, contains('#define PTY_READ_BUFFER_SIZE (128 * 1024)'));
    expect(nativeSource, contains('#define PTY_RUST_READ_WINDOW 32'));
    expect(nativeSource, contains('char buffer[PTY_READ_BUFFER_SIZE]'));
    expect(nativeSource, contains('if (options->waitForReadAck)'));
    expect(
      nativeSource,
      contains('handle->rust_read_credits = PTY_RUST_READ_WINDOW'),
    );
    expect(nativeSource, contains('handle->rust_read_credits--'));
    expect(
      nativeSource,
      contains('handle->rust_read_credits < PTY_RUST_READ_WINDOW'),
    );
    expect(nativeSource, contains('handle->rust_read_credits++'));
    expect(nativeSource, isNot(contains('char buffer[1024]')));
    expect(nativeSource, isNot(contains('rust_read_permit')));
  });

  test('macOS build isolates and load-checks Rust dylibs', () {
    final project = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    expect(project, contains('RUST_BUILD_ROOT='));
    expect(project, contains('CARGO_TARGET_DIR='));
    expect(project, contains('TARGET_TEMP_DIR'));
    expect(project, contains('/usr/bin/shlock'));
    expect(project, contains('trap cleanup_rust_lock EXIT INT TERM'));
    expect(project, contains('env -u MACOSX_DEPLOYMENT_TARGET'));
    expect(project, contains("ctypes.CDLL(sys.argv[1])"));
    expect(
      project,
      isNot(
        contains('native/pty_core/target/release/libssterm_pty_core.dylib'),
      ),
    );
  });
}
