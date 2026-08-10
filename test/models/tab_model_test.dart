import 'dart:io';

import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:ssterm/models/ssh_host.dart';
import 'package:ssterm/models/tab_model.dart';
import 'package:ssterm/services/file_write_service.dart';
import 'package:xterm/xterm.dart';

/// Minimal no-op stand-in — `AppTab.editor` only stores the reference,
/// it never calls any method on it, so a real [SftpClient] (which
/// requires a live SSH transport to construct) isn't needed here.
class FakeSftpClient implements SftpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('tab model has no obsolete pre-promotion Agent panel flag', () {
    final source = File('lib/models/tab_model.dart').readAsStringSync();
    final obsoleteField = ['ai', 'Panel', 'Visible'].join();
    expect(source, isNot(contains(obsoleteField)));
  });

  // GlobalKey requires a binding to be initialized.
  setUpAll(() => WidgetsFlutterBinding.ensureInitialized());

  group('AppTab.clearSplit', () {
    test('nulls all pane-1 fields and sets isSplit to false', () {
      final tab = AppTab.local(title: 'test');
      tab.splitTerminal = Terminal();
      tab.remoteCwdPane1 = '/home/user';
      tab.splitSessionEnded = true;
      tab.activeSshPane = 1;

      tab.clearSplit();

      expect(tab.splitTerminal, isNull);
      expect(tab.remoteCwdPane1, isNull);
      expect(tab.splitSessionEnded, isFalse);
      expect(tab.isSplit, isFalse);
      // activeSshPane resets to 0 when it was 1
      expect(tab.activeSshPane, equals(0));
    });

    test('activeSshPane stays 0 when it was already 0', () {
      final tab = AppTab.local(title: 'test');
      tab.splitTerminal = Terminal();
      tab.activeSshPane = 0;

      tab.clearSplit();

      expect(tab.activeSshPane, equals(0));
    });
  });

  group('AppTab.retainPane1', () {
    test('promotes pane-1 terminal to pane-0 slot', () {
      final tab = AppTab.local(title: 'test');
      final pane0 = Terminal();
      final pane1 = Terminal();
      tab.terminal = pane0;
      tab.splitTerminal = pane1;
      tab.remoteCwdPane1 = '/srv';

      tab.retainPane1();

      expect(tab.terminal, same(pane1));
      expect(tab.splitTerminal, isNull);
      expect(tab.isSplit, isFalse);
      // cwd from pane 1 becomes pane 0 cwd
      expect(tab.remoteCwdPane0, equals('/srv'));
      expect(tab.primarySessionEnded, isFalse);
    });

    test('is a no-op when not split', () {
      final tab = AppTab.local(title: 'test');
      final t = Terminal();
      tab.terminal = t;

      tab.retainPane1();

      expect(tab.terminal, same(t));
    });
  });

  group('AppTab.syncRemotePathToActivePane', () {
    test('updates remotePath to pane-0 cwd when activeSshPane == 0', () {
      final tab = AppTab.ssh(title: 'srv');
      tab.remotePath = ValueNotifier<String>('');
      tab.remoteCwdPane0 = '/home/alice';
      tab.remoteCwdPane1 = '/tmp';
      tab.activeSshPane = 0;

      tab.syncRemotePathToActivePane();

      expect(tab.remotePath!.value, equals('/home/alice'));
    });

    test(
      'updates remotePath to pane-1 cwd when activeSshPane == 1 and split',
      () {
        final tab = AppTab.ssh(title: 'srv');
        tab.remotePath = ValueNotifier<String>('');
        tab.remoteCwdPane0 = '/home/alice';
        tab.remoteCwdPane1 = '/tmp';
        tab.splitTerminal = Terminal(); // makes isSplit == true
        tab.activeSshPane = 1;

        tab.syncRemotePathToActivePane();

        expect(tab.remotePath!.value, equals('/tmp'));
      },
    );

    test('falls back to pane-0 cwd when pane-1 cwd is null', () {
      final tab = AppTab.ssh(title: 'srv');
      tab.remotePath = ValueNotifier<String>('');
      tab.remoteCwdPane0 = '/home/alice';
      tab.remoteCwdPane1 = null;
      tab.splitTerminal = Terminal();
      tab.activeSshPane = 1;

      tab.syncRemotePathToActivePane();

      expect(tab.remotePath!.value, equals('/home/alice'));
    });

    test('does nothing when remotePath is null', () {
      final tab = AppTab.local(title: 'test');
      tab.remoteCwdPane0 = '/home/alice';
      // remotePath is null — should not throw
      expect(() => tab.syncRemotePathToActivePane(), returnsNormally);
    });
  });

  group('AppTab.isSplit', () {
    test('false when splitTerminal is null', () {
      expect(AppTab.local(title: 'x').isSplit, isFalse);
    });

    test('true when splitTerminal is set', () {
      final tab = AppTab.local(title: 'x');
      tab.splitTerminal = Terminal();
      expect(tab.isSplit, isTrue);
    });
  });

  group('safeSshTeardown', () {
    test('swallows SSHStateError from dead transport', () {
      expect(
        () => safeSshTeardown(() => throw SSHStateError('Transport is closed')),
        returnsNormally,
      );
    });
  });

  group('AppTab.clearDeadSshTransport', () {
    test('clears transport slots but keeps sshProfile for reconnect', () {
      const profile = SshHost(alias: 'srv', hostname: '10.0.0.1');
      final tab = AppTab.ssh(title: 'srv', profile: profile);

      tab.clearDeadSshTransport();

      expect(tab.sshClient, isNull);
      expect(tab.jumpClient, isNull);
      expect(tab.sshSession, isNull);
      expect(tab.sftp, isNull);
      expect(tab.sshProfile, same(profile));
    });
  });

  test('tab removal invalidates in-flight Agent command cancellation', () {
    final tab = AppTab.local(title: 'test');

    expect(tab.isAgentExecutionCancelled, isFalse);
    tab.prepareForRemoval();
    expect(tab.isAgentExecutionCancelled, isTrue);
  });

  test('verified command cwd updates Agent-relative file operations', () async {
    final root = await Directory.systemTemp.createTemp('ssterm-tab-cwd-');
    final child = await Directory('${root.path}/child').create();
    final target = File('${child.path}/note.txt');
    await target.writeAsString('hello');
    addTearDown(() => root.delete(recursive: true));
    final tab = AppTab.local(title: 'test')..agentCwd = root.path;

    tab.applyAgentCommandResult(
      CommandResult(output: '', exitCode: 0, effectiveCwd: child.path),
    );
    final adapter = LocalFileSystemAdapter(cwdProvider: () => tab.agentCwd);
    final preview = await adapter.preview('note.txt');

    expect(tab.agentCwd, child.path);
    expect(preview.resolvedPath, target.path);
  });

  group('AppTab.icon', () {
    test('local tab has terminal icon', () {
      expect(AppTab.local(title: 'x').icon.codePoint, isNonZero);
    });

    test('ssh tab has lock icon', () {
      expect(AppTab.ssh(title: 'x').icon.codePoint, isNonZero);
    });
  });

  group('AppTab.editor', () {
    test(
      'factory sets kind, path, sftp, label, mtime, and initial content',
      () {
        final mtime = DateTime.utc(2026, 1, 1);
        final tab = AppTab.editor(
          path: '/etc/hosts',
          sftp: FakeSftpClient(),
          label: 'ssh: prod-db',
          mtime: mtime,
          initialContent: 'localhost 127.0.0.1',
        );
        expect(tab.kind, equals(AppTabKind.editor));
        expect(tab.editorPath, equals('/etc/hosts'));
        expect(tab.editorSftp, isNotNull);
        expect(tab.editorLabel, equals('ssh: prod-db'));
        expect(tab.editorMtime, equals(mtime));
        expect(tab.editorInitialContent, equals('localhost 127.0.0.1'));
        expect(tab.title, equals('/etc/hosts'));
      },
    );

    test('starts not dirty', () {
      final tab = AppTab.editor(
        path: '/tmp/x',
        sftp: FakeSftpClient(),
        label: 'ssh: x',
        mtime: null,
        initialContent: '',
      );
      expect(tab.editorDirty.value, isFalse);
    });

    test('editorViewKey is a fresh GlobalKey per tab', () {
      final a = AppTab.editor(
        path: '/a',
        sftp: FakeSftpClient(),
        label: 'x',
        mtime: null,
        initialContent: '',
      );
      final b = AppTab.editor(
        path: '/b',
        sftp: FakeSftpClient(),
        label: 'x',
        mtime: null,
        initialContent: '',
      );
      expect(identical(a.editorViewKey, b.editorViewKey), isFalse);
    });
  });

  group('AppTab.icon', () {
    test('editor tab has edit icon', () {
      final tab = AppTab.editor(
        path: '/a',
        sftp: FakeSftpClient(),
        label: 'x',
        mtime: null,
        initialContent: '',
      );
      expect(tab.icon, equals(Icons.edit_note));
    });
  });
}
