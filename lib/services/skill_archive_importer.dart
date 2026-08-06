import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models/skill.dart';
import 'skill_service.dart';

/// Validates and installs a user-provided Skill ZIP archive.
class SkillArchiveImporter {
  SkillArchiveImporter({String? skillsDirectory})
    : skillsDirectory = skillsDirectory ?? SkillService.userSkillsDirPath;

  final String skillsDirectory;

  static const _maxArchiveBytes = 10 * 1024 * 1024;
  static const _maxFiles = 100;

  Future<SkillArchiveImportResult> importZip(String archivePath) async {
    final source = File(archivePath);
    if (!await source.exists()) {
      throw const SkillArchiveImportException('找不到该 ZIP 文件。');
    }
    if (await source.length() > _maxArchiveBytes) {
      throw const SkillArchiveImportException('Skill ZIP 不能超过 10 MB。');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    } catch (_) {
      throw const SkillArchiveImportException('无法读取 ZIP 文件。');
    }
    if (archive.isEmpty || archive.length > _maxFiles) {
      throw const SkillArchiveImportException('ZIP 内容为空或文件数量超过限制。');
    }

    final paths = <ArchiveFile, List<String>>{};
    String? skillId;
    var totalBytes = 0;
    for (final entry in archive) {
      final parts = _safeParts(entry.name);
      if (parts == null || parts.isEmpty || entry.isSymbolicLink) {
        throw const SkillArchiveImportException('ZIP 包含不安全的文件路径。');
      }
      final root = parts.first;
      if (!_skillIdPattern.hasMatch(root)) {
        throw const SkillArchiveImportException('Skill 文件夹名称必须为小写字母、数字、- 或 _。');
      }
      if (skillId != null && skillId != root) {
        throw const SkillArchiveImportException('ZIP 必须只包含一个 Skill 文件夹。');
      }
      skillId = root;
      if (entry.isFile) {
        totalBytes += entry.size;
        if (totalBytes > _maxArchiveBytes) {
          throw const SkillArchiveImportException('解压后的 Skill 内容不能超过 10 MB。');
        }
      }
      paths[entry] = parts;
    }

    final id = skillId!;
    if (!paths.values.any((parts) => parts.join('/') == '$id/SKILL.md')) {
      throw SkillArchiveImportException('ZIP 必须包含 $id/SKILL.md。');
    }

    final destination = Directory(p.join(skillsDirectory, id));
    if (await destination.exists()) {
      throw SkillArchiveImportException('Skill “$id” 已存在，请先删除或更换名称。');
    }

    final parent = Directory(skillsDirectory)..createSync(recursive: true);
    final staging = await parent.createTemp('.skill-import-$id-');
    try {
      for (final entry in archive) {
        final relativeParts = paths[entry]!;
        final target = p.joinAll([staging.path, ...relativeParts]);
        if (!p.isWithin(staging.path, target)) {
          throw const SkillArchiveImportException('ZIP 包含不安全的文件路径。');
        }
        if (entry.isDirectory) {
          await Directory(target).create(recursive: true);
        } else {
          final bytes = entry.readBytes();
          if (bytes == null) {
            throw const SkillArchiveImportException('无法读取 ZIP 内容。');
          }
          await File(target)
              .create(recursive: true)
              .then((file) => file.writeAsBytes(bytes, flush: true));
        }
      }

      final skillFile = File(p.join(staging.path, id, 'SKILL.md'));
      final raw = await skillFile.readAsString();
      if (Skill.tryParse(id: id, assetPath: skillFile.path, raw: raw) == null) {
        throw const SkillArchiveImportException(
          'SKILL.md 缺少有效的 name 或 description。',
        );
      }
      await Directory(p.join(staging.path, id)).rename(destination.path);
      return SkillArchiveImportResult(skillId: id);
    } finally {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  static final _skillIdPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  static List<String>? _safeParts(String rawPath) {
    final normalized = rawPath.replaceAll('\\', '/');
    if (normalized.startsWith('/') || normalized.contains('\u0000')) {
      return null;
    }
    final parts = normalized
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.any(
      (part) => part == '.' || part == '..' || part.contains(':'),
    )) {
      return null;
    }
    return parts;
  }
}

class SkillArchiveImportResult {
  const SkillArchiveImportResult({required this.skillId});

  final String skillId;
}

class SkillArchiveImportException implements Exception {
  const SkillArchiveImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
