import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/utils/ssh_error_messages.dart';

void main() {
  group('friendlyConnectError', () {
    test('auth failure keywords → friendly auth message', () {
      for (final raw in [
        'UserAuth failed',
        'authentication required',
        'Permission denied',
      ]) {
        expect(
          friendlyConnectError(raw),
          equals('Authentication failed, check password or key'),
          reason: 'raw="$raw"',
        );
      }
    });

    test('connection refused → friendly refused message', () {
      expect(
        friendlyConnectError('Connection refused'),
        equals('Connection refused, check IP and port'),
      );
    });

    test('timeout keywords → friendly timeout message', () {
      for (final raw in ['Connection timeout', 'operation timedout']) {
        expect(
          friendlyConnectError(raw),
          equals('Connection timed out'),
          reason: 'raw="$raw"',
        );
      }
    });

    test('host-key keywords → friendly host key message', () {
      for (final raw in ['HostKey mismatch', 'host key changed']) {
        expect(
          friendlyConnectError(raw),
          equals('Host key verification failed'),
          reason: 'raw="$raw"',
        );
      }
    });

    test('DNS / socket keywords → friendly resolve message', () {
      for (final raw in ['nodename not found', 'SocketException: connection']) {
        expect(
          friendlyConnectError(raw),
          equals('Cannot resolve host'),
          reason: 'raw="$raw"',
        );
      }
    });

    test('unknown error → stripped Exception/Error prefix', () {
      expect(
        friendlyConnectError('Exception: something weird happened'),
        equals('something weird happened'),
      );
      expect(
        friendlyConnectError('Error: bad config'),
        equals('bad config'),
      );
    });

    test('plain message with no prefix passes through unchanged', () {
      expect(
        friendlyConnectError('something weird happened'),
        equals('something weird happened'),
      );
    });
  });
}
