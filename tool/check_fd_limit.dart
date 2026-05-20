// One-off probe: verify raiseFileDescriptorLimit() actually moves
// RLIMIT_NOFILE on this host. Run with:
//   dart run tool/check_fd_limit.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:ssterm/utils/fd_limit.dart';

final class _Rlimit extends Struct {
  @Uint64()
  external int softLimit;
  @Uint64()
  external int hardLimit;
}

typedef _GetrlimitNative = Int32 Function(Int32, Pointer<_Rlimit>);
typedef _GetrlimitDart = int Function(int, Pointer<_Rlimit>);

void main() {
  final res = (Platform.isMacOS || Platform.isIOS) ? 8 : 7;
  final libc = DynamicLibrary.process();
  final getrlimit =
      libc.lookupFunction<_GetrlimitNative, _GetrlimitDart>('getrlimit');

  final rlim = calloc<_Rlimit>();
  getrlimit(res, rlim);
  stdout.writeln(
      'BEFORE  soft=${rlim.ref.softLimit}  hard=${rlim.ref.hardLimit}');

  raiseFileDescriptorLimit();

  getrlimit(res, rlim);
  stdout.writeln(
      'AFTER   soft=${rlim.ref.softLimit}  hard=${rlim.ref.hardLimit}');
  calloc.free(rlim);
}
