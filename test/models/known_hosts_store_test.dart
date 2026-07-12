import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/known_hosts_store.dart';

void main() {
  group('KnownHostsStore.trust', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot =
          await Directory.systemTemp.createTemp('ssterm-known-hosts-test-');
      KnownHostsStore.debugDirOverride = tempRoot.path;
    });

    tearDown(() async {
      KnownHostsStore.debugDirOverride = null;
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('trusting a new host/port creates one entry', () async {
      await KnownHostsStore.trust(
          'example.com', 22, 'ssh-ed25519', 'aa:bb:cc');

      final entries = await KnownHostsStore.load();
      expect(entries, hasLength(1));
      expect(entries.single.hostname, equals('example.com'));
      expect(entries.single.port, equals(22));
      expect(entries.single.keyType, equals('ssh-ed25519'));
      expect(entries.single.fingerprint, equals('aabbcc'));
    });

    test('trusting an already-known host/port replaces, not appends',
        () async {
      await KnownHostsStore.trust(
          'example.com', 22, 'ssh-ed25519', 'aa:bb:cc');
      await KnownHostsStore.trust(
          'example.com', 22, 'ssh-ed25519', 'dd:ee:ff');

      final entries = await KnownHostsStore.load();
      expect(
        entries,
        hasLength(1),
        reason: 'updating a host key must replace the old fingerprint, '
            'not add a second entry for the same host/port',
      );
      expect(entries.single.fingerprint, equals('ddeeff'));
    });

    test('trust() for one host/port does not disturb another', () async {
      await KnownHostsStore.trust(
          'example.com', 22, 'ssh-ed25519', 'aa:bb:cc');
      await KnownHostsStore.trust('other.com', 22, 'ssh-ed25519', '11:22:33');
      await KnownHostsStore.trust(
          'example.com', 22, 'ssh-ed25519', 'dd:ee:ff');

      final entries = await KnownHostsStore.load();
      expect(entries, hasLength(2));
      final other = entries.firstWhere((e) => e.hostname == 'other.com');
      expect(other.fingerprint, equals('112233'));
      final example = entries.firstWhere((e) => e.hostname == 'example.com');
      expect(example.fingerprint, equals('ddeeff'));
    });
  });
}
