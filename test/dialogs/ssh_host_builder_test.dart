import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/dialogs/ssh_host_builder.dart';

void main() {
  group('buildSshHostResult validation', () {
    test('empty host returns error', () {
      final r = buildSshHostResult(
        hostText: '',
        userText: 'alice',
        portText: '22',
        aliasText: '',
        authMode: SshAuthMode.password,
        passwordText: 'secret',
        existingPassword: null,
        keyText: '',
        forwardRules: const [],
        jumpHost: null,
        keepaliveInterval: 0,
        autoReconnect: false,
        sessionLog: false,
      );
      expect(r, isA<SshHostFormError>());
      expect((r as SshHostFormError).message, contains('hostname'));
    });

    test('empty user returns error', () {
      final r = buildSshHostResult(
        hostText: '10.0.0.1',
        userText: '',
        portText: '22',
        aliasText: '',
        authMode: SshAuthMode.password,
        passwordText: '',
        existingPassword: null,
        keyText: '',
        forwardRules: const [],
        jumpHost: null,
        keepaliveInterval: 0,
        autoReconnect: false,
        sessionLog: false,
      );
      expect(r, isA<SshHostFormError>());
      expect((r as SshHostFormError).message, contains('sername'));
    });

    test('port out of range returns error', () {
      final r = buildSshHostResult(
        hostText: '10.0.0.1',
        userText: 'alice',
        portText: '99999',
        aliasText: '',
        authMode: SshAuthMode.password,
        passwordText: '',
        existingPassword: null,
        keyText: '',
        forwardRules: const [],
        jumpHost: null,
        keepaliveInterval: 0,
        autoReconnect: false,
        sessionLog: false,
      );
      expect(r, isA<SshHostFormError>());
      expect((r as SshHostFormError).message, contains('port'));
    });
  });

  group('buildSshHostResult success', () {
    SshHostFormSuccess success({
      String host = '10.0.0.1',
      String user = 'alice',
      String port = '22',
      String alias = '',
      SshAuthMode authMode = SshAuthMode.password,
      String password = 'pw',
      String? existingPassword,
      String key = '',
    }) {
      final r = buildSshHostResult(
        hostText: host,
        userText: user,
        portText: port,
        aliasText: alias,
        authMode: authMode,
        passwordText: password,
        existingPassword: existingPassword,
        keyText: key,
        forwardRules: const [],
        jumpHost: null,
        keepaliveInterval: 0,
        autoReconnect: false,
        sessionLog: false,
      );
      return r as SshHostFormSuccess;
    }

    test('builds SshHost with correct hostname and user', () {
      final h = success().host;
      expect(h.hostname, equals('10.0.0.1'));
      expect(h.user, equals('alice'));
    });

    test('auto-alias uses user@host when alias is empty', () {
      final h = success(alias: '').host;
      expect(h.alias, equals('alice@10.0.0.1'));
    });

    test('auto-alias appends :port when port is non-standard', () {
      final h = success(port: '2222', alias: '').host;
      expect(h.alias, equals('alice@10.0.0.1:2222'));
    });

    test('custom alias is preserved', () {
      final h = success(alias: 'my-server').host;
      expect(h.alias, equals('my-server'));
    });

    test('password auth sets password and clears identityFile', () {
      final h = success(authMode: SshAuthMode.password, password: 'pw').host;
      expect(h.password, equals('pw'));
      expect(h.identityFile, isNull);
    });

    test('key auth sets identityFile and clears password', () {
      final h = success(authMode: SshAuthMode.key, key: '/id_rsa', password: '').host;
      expect(h.identityFile, equals('/id_rsa'));
      expect(h.password, isNull);
    });

    test('empty password falls back to existingPassword', () {
      final h = success(
        authMode: SshAuthMode.password,
        password: '',
        existingPassword: 'old-pass',
      ).host;
      expect(h.password, equals('old-pass'));
    });
  });
}
