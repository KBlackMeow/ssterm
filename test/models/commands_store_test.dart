import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/command.dart';
import 'package:ssterm/models/commands_store.dart';

void main() {
  test('persists newly created commands', () async {
    final dir = await Directory.systemTemp.createTemp('ssterm-command-test-');
    CommandsStore.debugFileOverride = File('${dir.path}/commands.json');
    addTearDown(() async {
      CommandsStore.debugFileOverride = null;
      await dir.delete(recursive: true);
    });

    await CommandsStore.save(const [
      Command(
        name: 'List files',
        description: 'Shows the current directory',
        command: 'ls -la',
      ),
    ]);

    final commands = await CommandsStore.load();
    expect(commands, hasLength(1));
    expect(commands.single.command, 'ls -la');
  });
}
