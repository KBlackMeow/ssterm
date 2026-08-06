import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/skill_archive_importer.dart';

void main() {
  group('SkillArchiveImporter', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('ssterm-skill-zip-');
    });

    tearDown(() async {
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    });

    test('installs a valid single-root skill archive', () async {
      final archiveFile = File('${tempRoot.path}/git-helper.zip');
      final archive = Archive()
        ..addFile(
          ArchiveFile.string('git-helper/SKILL.md', '''---
name: Git helper
description: Helps with Git tasks.
---
# Git helper
'''),
        )
        ..addFile(
          ArchiveFile.string('git-helper/references/notes.md', 'notes'),
        );
      await archiveFile.writeAsBytes(ZipEncoder().encodeBytes(archive)!);

      final result = await SkillArchiveImporter(
        skillsDirectory: '${tempRoot.path}/installed',
      ).importZip(archiveFile.path);

      expect(result.skillId, 'git-helper');
      expect(
        File('${tempRoot.path}/installed/git-helper/SKILL.md').readAsString(),
        completion(contains('description: Helps with Git tasks.')),
      );
      expect(
        File(
          '${tempRoot.path}/installed/git-helper/references/notes.md',
        ).exists(),
        completion(isTrue),
      );
    });

    test('rejects an archive with files outside the Skill root', () async {
      final archiveFile = File('${tempRoot.path}/unsafe.zip');
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'safe-skill/SKILL.md',
            '---\nname: Safe\ndescription: Safe skill.\n---\n',
          ),
        )
        ..addFile(ArchiveFile.string('../outside.txt', 'not allowed'));
      await archiveFile.writeAsBytes(ZipEncoder().encodeBytes(archive)!);

      expect(
        SkillArchiveImporter(
          skillsDirectory: '${tempRoot.path}/installed',
        ).importZip(archiveFile.path),
        throwsA(isA<SkillArchiveImportException>()),
      );
      expect(
        File('${tempRoot.path}/outside.txt').exists(),
        completion(isFalse),
      );
    });

    test('rejects a zip without a valid SKILL.md', () async {
      final archiveFile = File('${tempRoot.path}/missing-skill-md.zip');
      final archive = Archive()
        ..addFile(ArchiveFile.string('missing/readme.md', '# Not a skill'));
      await archiveFile.writeAsBytes(ZipEncoder().encodeBytes(archive)!);

      expect(
        SkillArchiveImporter(
          skillsDirectory: '${tempRoot.path}/installed',
        ).importZip(archiveFile.path),
        throwsA(isA<SkillArchiveImportException>()),
      );
    });
  });
}
