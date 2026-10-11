import 'dart:io';

/// Creates an isolated fixture for the manual/live Agent evaluation matrix.
Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('ssterm-agent-eval-');
  Future<void> write(String relativePath, String content) async {
    final file = File('${root.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  await write(
    'notes/alpha.txt',
    'alpha\nbeta\ngamma\nfinal-marker: ORCHID-42\n',
  );
  await write('notes/unicode.txt', '第一行\nemoji: 🐈\n最后一行：蓝色\n');
  await write('notes/case.txt', 'Moon\nmoon\nMOON\nsun\n');
  await write('data/settings.json', '{"mode":"safe","limit":7}\n');
  await write('data/records.csv', 'id,status\n1,ok\n2,failed\n3,ok\n');
  await write(
    'src/parser.dart',
    'int parsePort(String value) => int.parse(value);\n',
  );
  await write('src/answer.txt', 'The release code is COPPER-19.\n');
  await write(
    'logs/build.log',
    '${'INFO background activity\n' * 7000}'
        'ERROR: missing config marker: NEBULA-73\n'
        '${'INFO recovery activity\n' * 7000}',
  );
  await write(
    'large/huge.txt',
    '${'ordinary line\n' * 400000}'
        'tail marker: HORIZON-88\n',
  );
  await write('empty.txt', '');
  stdout.writeln(root.path);
}
