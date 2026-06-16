import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_pty/src/flutter_pty_bindings_generated.dart';

const _libName = 'flutter_pty';

final DynamicLibrary _dylib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

final _bindings = FlutterPtyBindings(_dylib);

final _init = () {
  return _bindings.Dart_InitializeApiDL(NativeApi.initializeApiDLData);
}();

void _ensureInitialized() {
  if (_init != 0) {
    throw StateError('Failed to initialize native bindings');
  }
}

/// Exception thrown when [Pty.start] fails or times out.
class PtyStartException implements Exception {
  final String message;
  const PtyStartException(this.message);
  @override
  String toString() => message;
}

/// Runs [pty_create] inside a background isolate so the main isolate never
/// blocks on the FFI call.  Returns the raw pointer address on success or -1
/// on failure (caller reads [pty_error] for the message).
@pragma('vm:entry-point')
int _ptyCreateInIsolate({
  required int stdoutPort,
  required int exitPort,
  required String executable,
  required List<String> arguments,
  String? workingDirectory,
  required List<String> envPairs,
  required int rows,
  required int columns,
  required bool ackRead,
}) {
  _ensureInitialized(); // per-isolate Dart API DL init

  final executableNative = executable.toNativeUtf8();
  final workingDirectoryNative = workingDirectory?.toNativeUtf8();

  final argv = calloc<Pointer<Utf8>>(arguments.length + 2);
  argv[0] = executable.toNativeUtf8();
  for (var i = 0; i < arguments.length; i++) {
    argv[i + 1] = arguments[i].toNativeUtf8();
  }
  argv[arguments.length + 1] = nullptr;

  final envp = calloc<Pointer<Utf8>>(envPairs.length + 1);
  for (var i = 0; i < envPairs.length; i++) {
    envp[i] = envPairs[i].toNativeUtf8();
  }
  envp[envPairs.length] = nullptr;

  final options = calloc<PtyOptions>();
  options.ref.rows = rows;
  options.ref.cols = columns;
  options.ref.executable = executableNative.cast();
  options.ref.arguments = argv.cast();
  options.ref.environment = envp.cast();
  options.ref.stdout_port = stdoutPort;
  options.ref.exit_port = exitPort;
  options.ref.ackRead = ackRead;

  if (workingDirectory != null) {
    options.ref.working_directory = workingDirectoryNative!.cast();
  } else {
    options.ref.working_directory = nullptr;
  }

  final Pointer<PtyHandle> handle;
  try {
    handle = _bindings.pty_create(options);
  } finally {
    calloc.free(options);
    malloc.free(executableNative);
    if (workingDirectoryNative != null) {
      malloc.free(workingDirectoryNative);
    }
    for (var i = 0; i < arguments.length + 1; i++) {
      malloc.free(argv[i]);
    }
    calloc.free(argv);
    for (var i = 0; i < envPairs.length; i++) {
      malloc.free(envp[i]);
    }
    calloc.free(envp);
  }

  if (handle == nullptr) return -1;
  return handle.address;
}

/// Pty represents a process running in a pseudo-terminal.
///
/// To create a Pty, use [Pty.start].
class Pty {
  final String executable;

  final List<String> arguments;

  final ReceivePort _stdoutPort;

  final ReceivePort _exitPort;

  final _exitCodeCompleter = Completer<int>();

  StreamSubscription<dynamic>? _exitSubscription;

  late final Pointer<PtyHandle> _handle;

  var _disposed = false;

  Pty._({
    required this.executable,
    required this.arguments,
    required Pointer<PtyHandle> handle,
    required ReceivePort stdoutPort,
    required ReceivePort exitPort,
  }) : _handle = handle,
       _stdoutPort = stdoutPort,
       _exitPort = exitPort {
    _exitSubscription = _exitPort.listen(_onExitCode);
  }

  /// Spawns a process in a pseudo-terminal inside a background isolate so the
  /// main isolate never blocks on [pty_create].  The arguments have the same
  /// meaning as in [Process.start].
  ///
  /// Has a 30-second timeout; throws [PtyStartException] on timeout.
  /// [ackRead] indicates if the pty should wait for a call to [Pty.ackRead]
  /// before sending the next data.
  static Future<Pty> start(
    String executable, {
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
    int rows = 25,
    int columns = 80,
    bool ackRead = false,
  }) async {
    _ensureInitialized();

    final effectiveEnv = <String, String>{};
    final useExactEnv = environment?['SSTERM_EXACT_ENV'] == '1';

    effectiveEnv['TERM'] = 'xterm-256color';
    // Without this, tools like "vi" produce sequences that are not UTF-8 friendly
    effectiveEnv['LANG'] = 'en_US.UTF-8';

    const envValuesToCopy = {
      'LOGNAME',
      'USER',
      'DISPLAY',
      'LC_TYPE',
      'HOME',
      'PATH'
    };

    if (!useExactEnv) {
      for (var entry in Platform.environment.entries) {
        if (envValuesToCopy.contains(entry.key)) {
          effectiveEnv[entry.key] = entry.value;
        }
      }
    }

    if (environment != null) {
      for (var entry in environment.entries) {
        if (entry.key == 'SSTERM_EXACT_ENV') continue;
        effectiveEnv[entry.key] = entry.value;
      }
    }

    final envPairs = effectiveEnv.entries
        .map((e) => '${e.key}=${e.value}')
        .toList();

    // Create ReceivePorts on the MAIN isolate so their nativePort IDs are
    // known before we launch the background isolate.  The C read_loop thread
    // posts to these ports via process-global Dart_PostCObject_DL — this
    // works across isolates because port IDs are process-global.
    final stdoutPort = ReceivePort();
    final exitPort = ReceivePort();

    // Extract native port IDs BEFORE the Isolate.run closure so the closure
    // captures only ints, not the unsendable ReceivePort objects.
    final stdoutPortId = stdoutPort.sendPort.nativePort;
    final exitPortId = exitPort.sendPort.nativePort;

    try {
      final handleAddr = await Isolate.run(() => _ptyCreateInIsolate(
            stdoutPort: stdoutPortId,
            exitPort: exitPortId,
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            envPairs: envPairs,
            rows: rows,
            columns: columns,
            ackRead: ackRead,
          ))
          .timeout(const Duration(seconds: 30));

      if (handleAddr == -1) {
        final err = _getPtyError();
        throw PtyStartException(
          err != null ? 'Failed to create PTY: $err' : 'Failed to create PTY',
        );
      }

      final handle = Pointer<PtyHandle>.fromAddress(handleAddr);
      return Pty._(
        executable: executable,
        arguments: arguments,
        handle: handle,
        stdoutPort: stdoutPort,
        exitPort: exitPort,
      );
    } on TimeoutException {
      stdoutPort.close();
      exitPort.close();
      throw PtyStartException(
        'Terminal creation timed out after 30 seconds. '
        'The shell process (e.g., WSL) may be hung.',
      );
    } catch (e) {
      stdoutPort.close();
      exitPort.close();
      rethrow;
    }
  }

  /// The output stream from the pseudo-terminal. Note that pseudo-terminals
  /// do not distinguish between stdout and stderr.
  Stream<Uint8List> get output => _stdoutPort.cast();

  /// A `Future` which completes with the exit code of the process
  /// when the process completes.
  ///
  /// The handling of exit codes is platform specific.
  ///
  /// On Linux and OS X a normal exit code will be a positive value in
  /// the range `[0..255]`. If the process was terminated due to a signal
  /// the exit code will be a negative value in the range `[-255..-1]`,
  /// where the absolute value of the exit code is the signal
  /// number. For example, if a process crashes due to a segmentation
  /// violation the exit code will be -11, as the signal SIGSEGV has the
  /// number 11.
  ///
  /// On Windows a process can report any 32-bit value as an exit
  /// code. When returning the exit code this exit code is turned into
  /// a signed value. Some special values are used to report
  /// termination due to some system event. E.g. if a process crashes
  /// due to an access violation the 32-bit exit code is `0xc0000005`,
  /// which will be returned as the negative number `-1073741819`. To
  /// get the original 32-bit value use `(0x100000000 + exitCode) &
  /// 0xffffffff`.
  ///
  /// There is no guarantee that [output] have finished reporting the buffered
  /// output of the process when the returned future completes.
  /// To be sure that all output is captured, wait for the done event on the
  /// streams.
  Future<int> get exitCode => _exitCodeCompleter.future;

  /// The process id of the process running in the pseudo-terminal.
  int get pid => _bindings.pty_getpid(_handle);

  /// Write data to the pseudo-terminal.
  void write(Uint8List data) {
    final buf = malloc<Int8>(data.length);
    buf.asTypedList(data.length).setAll(0, data);
    _bindings.pty_write(_handle, buf.cast(), data.length);
    malloc.free(buf);
  }

  /// Resize the pseudo-terminal.
  void resize(int rows, int cols) {
    _bindings.pty_resize(_handle, rows, cols);
  }

  /// Kill the process running in the pseudo-terminal.
  ///
  /// When possible, [signal] will be sent to the process. This includes
  /// Linux and OS X. The default signal is [ProcessSignal.sigterm]
  /// which will normally terminate the process.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_disposed) return false;
    return Process.killPid(pid, signal);
  }

  /// Releases the native PTY handle and Dart receive ports.
  ///
  /// This does not guarantee graceful shell shutdown; call [kill] first when
  /// the process should be terminated.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _exitSubscription?.cancel();
    _exitSubscription = null;
    // Close Dart receive ports FIRST so any in-flight read() on the IO thread
    // is cancelled before we close the underlying file descriptors.  Reversing
    // this order causes a kernel-level deadlock: the IO thread holds an
    // internal PTY lock inside read(), and the main thread's close() inside
    // pty_destroy blocks forever waiting for it.
    _stdoutPort.close();
    _exitPort.close();
    _bindings.pty_destroy(_handle);
  }

  /// indicates that a data chunk has been processed.
  /// This is needed when ackRead is set to true as the pty will wait for this signal to happen
  /// before any additional data is sent.
  void ackRead() {
    _bindings.pty_ack_read(_handle);
  }

  void _onExitCode(dynamic exitCode) {
    if (_disposed) return;
    _disposed = true;
    _exitSubscription?.cancel();
    _exitSubscription = null;
    _stdoutPort.close();
    _exitPort.close();
    _bindings.pty_destroy(_handle);
    _exitCodeCompleter.complete(exitCode);
  }
}

String? _getPtyError() {
  final error = _bindings.pty_error();

  if (error == nullptr) {
    return null;
  }

  return error.cast<Utf8>().toDartString();
}
