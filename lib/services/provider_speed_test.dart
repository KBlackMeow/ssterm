import 'dart:async';

import 'llm_service.dart';

/// A bounded streaming benchmark. Waits for startup separately, then samples
/// output for [ProviderSpeedTest.window]. Startup latency remains in the
/// elapsed time so slow-starting providers can be compared fairly.
class ProviderSpeedResult {
  const ProviderSpeedResult({
    required this.tokens,
    required this.exact,
    required this.elapsed,
    required this.firstToken,
  });

  final int tokens;
  final bool exact;
  final Duration elapsed;
  final Duration? firstToken;

  double get tokensPerSecond => elapsed.inMicroseconds == 0
      ? 0
      : tokens * 1000000 / elapsed.inMicroseconds;
  double get millisecondsPerToken =>
      tokens == 0 ? 0 : elapsed.inMicroseconds / 1000 / tokens;
}

class ProviderSpeedTest {
  ProviderSpeedTest({
    this.window = const Duration(seconds: 5),
    this.startupTimeout = const Duration(seconds: 30),
  });

  final Duration window;
  final Duration startupTimeout;
  void Function()? _cancel;

  void cancel() => _cancel?.call();

  Future<ProviderSpeedResult> run({
    required Stream<LlmStreamEvent> Function() start,
    required void Function() abort,
  }) async {
    final done = Completer<ProviderSpeedResult>();
    final clock = Stopwatch()..start();
    final output = StringBuffer();
    int? reportedTokens;
    Duration? firstToken;
    StreamSubscription<LlmStreamEvent>? subscription;
    Timer? timer;
    var finishing = false;

    void finish([Object? error, StackTrace? stack]) {
      // Closing the HTTP client or cancelling a subscription can synchronously
      // re-enter finish. Claim completion before calling either cleanup hook.
      if (finishing) return;
      finishing = true;
      clock.stop();
      timer?.cancel();
      abort();
      final current = subscription;
      if (current != null) unawaited(current.cancel());
      if (error != null) {
        done.completeError(error, stack);
      } else {
        // Approximation only: SSE chunks are not tokenizer tokens.
        final estimated = (output.length / 4).ceil();
        done.complete(
          ProviderSpeedResult(
            tokens: reportedTokens ?? estimated,
            exact: reportedTokens != null,
            elapsed: clock.elapsed,
            firstToken: firstToken,
          ),
        );
      }
    }

    _cancel = () => finish(StateError('Speed test cancelled.'));
    timer = Timer(startupTimeout, finish);
    try {
      subscription = start().listen(
        (event) {
          if (finishing) return;
          if ((event.kind == 'text' || event.kind == 'reasoning') &&
              event.content.isNotEmpty) {
            if (firstToken == null) {
              firstToken = clock.elapsed;
              timer?.cancel();
              timer = Timer(window, finish);
            }
            output.write(event.content);
          }
          if (event.completionTokenCount != null) {
            reportedTokens = event.completionTokenCount;
          }
        },
        onError: (Object error, StackTrace stack) => finish(error, stack),
        onDone: finish,
      );
      return await done.future;
    } catch (error, stack) {
      finish(error, stack);
      return await done.future;
    } finally {
      _cancel = null;
    }
  }
}
