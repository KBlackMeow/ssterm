import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/llm_service.dart';
import 'package:ssterm/services/provider_speed_test.dart';

void main() {
  test('deadline cleanup can synchronously re-enter cancellation', () async {
    final stream = StreamController<LlmStreamEvent>();
    final benchmark = ProviderSpeedTest(
      window: const Duration(milliseconds: 10),
      startupTimeout: const Duration(milliseconds: 10),
    );
    var aborts = 0;
    final result = await benchmark.run(
      start: () => stream.stream,
      abort: () {
        aborts++;
        if (aborts == 1) benchmark.cancel();
      },
    );
    expect(aborts, 1);
    expect(result.tokens, 0);
    await stream.close();
  });

  test('stream cancellation can synchronously re-enter finish', () async {
    final benchmark = ProviderSpeedTest(
      window: const Duration(milliseconds: 10),
      startupTimeout: const Duration(milliseconds: 10),
    );
    var aborts = 0;
    var cancellations = 0;
    final stream = StreamController<LlmStreamEvent>(
      onCancel: () {
        cancellations++;
        benchmark.cancel();
      },
    );
    final result = await benchmark.run(
      start: () => stream.stream,
      abort: () => aborts++,
    );
    expect(aborts, 1);
    expect(cancellations, 1);
    expect(result.firstToken, isNull);
    await stream.close();
  });

  test('uses reported tokens rather than counting stream chunks', () async {
    var aborted = false;
    final result = await ProviderSpeedTest().run(
      start: () => Stream.fromIterable([
        LlmStreamEvent('text', 'Hello world'),
        LlmStreamEvent.diagnostics(
          malformedEventCount: 0,
          completionTokenCount: 2,
        ),
      ]),
      abort: () => aborted = true,
    );
    expect(result.tokens, 2);
    expect(result.exact, isTrue);
    expect(result.firstToken, isNotNull);
    expect(aborted, isTrue);
  });

  test('deadline aborts a stream that never produces output', () async {
    final stream = StreamController<LlmStreamEvent>();
    var aborted = false;
    final result = await ProviderSpeedTest(
      window: const Duration(milliseconds: 20),
      startupTimeout: const Duration(milliseconds: 20),
    ).run(start: () => stream.stream, abort: () => aborted = true);
    expect(aborted, isTrue);
    expect(result.firstToken, isNull);
    expect(result.tokensPerSecond, 0);
    await stream.close();
  });

  test('waits for a slow first token before sampling output', () async {
    final result =
        await ProviderSpeedTest(
          window: const Duration(milliseconds: 10),
          startupTimeout: const Duration(milliseconds: 150),
        ).run(
          start: () async* {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            yield LlmStreamEvent('text', 'Hello from a slow provider');
          },
          abort: () {},
        );

    expect(result.firstToken, isNotNull);
    expect(result.firstToken!.inMilliseconds, greaterThanOrEqualTo(10));
    expect(result.tokens, greaterThan(0));
  });

  test(
    'partial output is explicitly estimated and includes reasoning',
    () async {
      final result = await ProviderSpeedTest().run(
        start: () => Stream.fromIterable([
          LlmStreamEvent('reasoning', 'abcd'),
          LlmStreamEvent('text', 'efgh'),
        ]),
        abort: () {},
      );
      expect(result.exact, isFalse);
      expect(result.tokens, 2);
      expect(result.tokensPerSecond, greaterThan(0));
    },
  );

  test('manual cancellation aborts without waiting for deadline', () async {
    final stream = StreamController<LlmStreamEvent>();
    final test = ProviderSpeedTest();
    var aborted = false;
    final future = test.run(
      start: () => stream.stream,
      abort: () => aborted = true,
    );
    final assertion = expectLater(future, throwsStateError);
    test.cancel();
    await assertion;
    expect(aborted, isTrue);
    await stream.close();
  });

  test('provider errors propagate and close the request', () async {
    var aborted = false;
    await expectLater(
      ProviderSpeedTest().run(
        start: () => Stream.error(StateError('unauthorized')),
        abort: () => aborted = true,
      ),
      throwsStateError,
    );
    expect(aborted, isTrue);
  });
}
