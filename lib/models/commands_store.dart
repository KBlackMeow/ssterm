import 'dart:convert';
import 'dart:io';

import '../utils/app_dir.dart';
import 'command.dart';

/// 读写用户自定义命令列表的文件存储。它与内置命令分开管理，负责 JSON
/// 转换及首次启动时的空列表回退。
class CommandsStore {
  /// 测试专用的命令文件路径覆盖值；为空时读写用户配置目录中的正式文件。
  static File? debugFileOverride;

  static Future<File> _file() async {
    final override = debugFileOverride;
    if (override != null) return override;
    final dir = await appDataDir();
    return File('${dir.path}/commands.json');
  }

  /// 读取用户命令 JSON；不存在或无法解析时返回空列表。
  static Future<List<Command>> load() async {
    final f = await _file();
    if (!await f.exists()) {
      return [];
    }
    try {
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      return list
          .map((e) => Command.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 将用户命令列表以缩进 JSON 写入配置目录或测试覆盖文件。
  static Future<void> save(List<Command> commands) async {
    final f = await _file();
    await f.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(commands.map((c) => c.toJson()).toList()),
    );
  }
}
