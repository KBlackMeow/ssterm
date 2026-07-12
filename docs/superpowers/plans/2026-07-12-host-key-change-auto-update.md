# SSH 主机密钥变化提示与自动更新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 当远程主机 SSH 密钥指纹与本地已保存的不一致时，弹窗警告并在用户确认后自动把新指纹写入 ssterm 自己的信任库，允许连接继续；取消则维持现状中止连接。

**Architecture:** 复用现有的主机密钥信任基础设施（`KnownHostsStore` / `TrustedHostKeys` / `host_key_verifier.dart` / `host_key_dialog.dart`）。把 `showHostKeyChangedDialog` 从一个只读警告改成一个返回 `bool` 的确认弹窗，`host_key_verifier.dart` 根据返回值决定是否调用已有的 `TrustedHostKeys.trust(...)` 写入新指纹并放行连接。不新增存储层逻辑。

**Tech Stack:** Flutter/Dart，`dartssh2` 提供主机密钥校验回调，`flutter_test` 做单元测试。

## Global Constraints

- 不修改系统级 `~/.ssh/known_hosts`；只更新 ssterm 自己的 `~/.ssterm/known_hosts.json`（dartssh2 的校验回调只提供 MD5 摘要，没有原始公钥字节，无法生成合法的 known_hosts 行）。
- "更新密钥并连接"按钮单击即确认，不加二次确认步骤（如勾选框）。
- `showDialog` 的 `barrierDismissible: false` 保持不变。
- 复用已有的 `TrustedHostKeys.trust(hostname, port, keyType, fingerprint)`，不新增存储方法。

---

## 参考：现有代码

`lib/services/host_key_verifier.dart`（完整内容，58 行）：

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../dialogs/host_key_dialog.dart';
import '../utils/ssh_fingerprint.dart';
import 'trusted_host_keys.dart';

typedef SshHostKeyVerifier = Future<bool> Function(
  String keyType,
  Uint8List fingerprint,
);

SshHostKeyVerifier createHostKeyVerifier(
  BuildContext context, {
  required String hostname,
  required int port,
}) {
  return (String keyType, Uint8List fingerprint) async {
    final fp = normalizeFingerprint(formatMd5Fingerprint(fingerprint));

    if (await TrustedHostKeys.isTrusted(hostname, port, keyType, fp)) {
      return true;
    }

    final conflict = await TrustedHostKeys.conflictingEntry(
      hostname,
      port,
      keyType,
      fp,
    );
    if (conflict != null) {
      if (!context.mounted) return false;
      await showHostKeyChangedDialog(
        context,
        hostname: hostname,
        port: port,
        existing: conflict,
        keyType: keyType,
        fingerprint: fp,
      );
      return false;
    }

    if (!context.mounted) return false;
    final accepted = await showHostKeyConfirmDialog(
      context,
      hostname: hostname,
      port: port,
      keyType: keyType,
      fingerprint: fp,
    );
    if (accepted) {
      await TrustedHostKeys.trust(hostname, port, keyType, fp);
    }
    return accepted;
  };
}
```

`lib/models/known_hosts_store.dart`（完整内容，88 行）：

```dart
import 'dart:convert';
import 'dart:io';

import '../utils/app_dir.dart';
import '../utils/ssh_fingerprint.dart';

class KnownHostEntry {
  final String hostname;
  final int port;
  final String keyType;
  final String fingerprint;

  const KnownHostEntry({
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });

  String get hostKey => port == 22 ? hostname : '[$hostname]:$port';

  Map<String, dynamic> toJson() => {
        'hostname': hostname,
        'port': port,
        'keyType': keyType,
        'fingerprint': fingerprint,
      };

  factory KnownHostEntry.fromJson(Map<String, dynamic> json) => KnownHostEntry(
        hostname: json['hostname'] as String,
        port: json['port'] as int? ?? 22,
        keyType: json['keyType'] as String,
        fingerprint: json['fingerprint'] as String,
      );
}

/// Trusted SSH server host keys (~/.ssterm/known_hosts.json).
class KnownHostsStore {
  static Future<File> _file() async {
    final dir = await appDataDir();
    return File('${dir.path}/known_hosts.json');
  }

  static Future<List<KnownHostEntry>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      return list
          .map((e) => KnownHostEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<KnownHostEntry> entries) async {
    final f = await _file();
    final data = entries.map((e) => e.toJson()).toList();
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  static Future<KnownHostEntry?> lookup(String hostname, int port) async {
    final entries = await load();
    for (final e in entries) {
      if (e.hostname == hostname && e.port == port) return e;
    }
    return null;
  }

  static Future<void> trust(
    String hostname,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    final entries = await load();
    entries.removeWhere((e) => e.hostname == hostname && e.port == port);
    entries.add(KnownHostEntry(
      hostname: hostname,
      port: port,
      keyType: keyType,
      fingerprint: normalizeFingerprint(fingerprint),
    ));
    await save(entries);
  }
}
```

参考已有的测试隔离约定（`lib/services/skill_service.dart:70` 的 `static String? debugUserSkillsDirOverride`，在 `test/services/skill_service_test.dart` 中通过 `Directory.systemTemp.createTemp(...)` + 赋值覆盖来隔离真实的 `~/.ssterm` 目录）。`KnownHostsStore` 目前没有对应的 override 钩子，直接跑单元测试会读写真实用户主目录下的 `~/.ssterm/known_hosts.json`，必须先补一个同样的钩子。

---

### Task 1: `KnownHostsStore` 测试隔离钩子 + `trust()` 替换行为回归测试

**Files:**
- Modify: `lib/models/known_hosts_store.dart:38-42`（`_file()` 方法）
- Create: `test/models/known_hosts_store_test.dart`

**Interfaces:**
- Produces: `KnownHostsStore.debugDirOverride`（`static String?`，测试专用，设置后 `_file()` 直接用这个目录而不调用 `appDataDir()`）。后续任务不依赖此接口。

- [ ] **Step 1: 给 `KnownHostsStore` 加测试隔离钩子**

在 `lib/models/known_hosts_store.dart` 里，把：

```dart
/// Trusted SSH server host keys (~/.ssterm/known_hosts.json).
class KnownHostsStore {
  static Future<File> _file() async {
    final dir = await appDataDir();
    return File('${dir.path}/known_hosts.json');
  }
```

改成：

```dart
/// Trusted SSH server host keys (~/.ssterm/known_hosts.json).
class KnownHostsStore {
  /// Overrides the directory used for the known-hosts file. Test-only —
  /// mirrors [SkillService.debugUserSkillsDirOverride] so tests don't
  /// read/write the real ~/.ssterm directory.
  static String? debugDirOverride;

  static Future<File> _file() async {
    final dirPath = debugDirOverride ?? (await appDataDir()).path;
    return File('$dirPath/known_hosts.json');
  }
```

其余方法（`load`/`save`/`lookup`/`trust`）不变。

- [ ] **Step 2: 写 `test/models/known_hosts_store_test.dart`**

```dart
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
```

- [ ] **Step 3: 跑测试确认全部通过**

Run: `flutter test test/models/known_hosts_store_test.dart`
Expected: `00:0X +3: All tests passed!`（3 个 test 全部 PASS，不读写真实的 `~/.ssterm` 目录）

- [ ] **Step 4: Commit**

```bash
git add lib/models/known_hosts_store.dart test/models/known_hosts_store_test.dart
git commit -m "$(cat <<'EOF'
Add test isolation hook + regression test for KnownHostsStore.trust replace behavior

Prepares for the host-key-change confirm/auto-update flow, which relies
on trust() replacing (not appending) the stored fingerprint for a
host/port.
EOF
)"
```

---

### Task 2: 主机密钥变化确认弹窗改为可操作，接入自动更新

**Files:**
- Modify: `lib/dialogs/host_key_dialog.dart:89-166`（`showHostKeyChangedDialog` 函数体）
- Modify: `lib/services/host_key_verifier.dart:32-43`（`conflict != null` 分支）

**Interfaces:**
- Consumes: `TrustedHostKeys.trust(String hostname, int port, String keyType, String fingerprint) → Future<void>`（已存在于 `lib/services/trusted_host_keys.dart`，Task 1 验证过其底层 `KnownHostsStore.trust` 的替换行为）。
- Produces: `showHostKeyChangedDialog(...) → Future<bool>`（原来是 `Future<void>`；`true` = 用户确认更新，`false` = 用户取消）。

- [ ] **Step 1: 修改 `showHostKeyChangedDialog` 签名、文案与按钮**

在 `lib/dialogs/host_key_dialog.dart` 里，把整个 `showHostKeyChangedDialog` 函数（从 `Future<void> showHostKeyChangedDialog(` 到匹配的收尾 `);`，即原文件第 89–166 行）替换为：

```dart
Future<bool> showHostKeyChangedDialog(
  BuildContext context, {
  required String hostname,
  required int port,
  required KnownHostEntry existing,
  required String keyType,
  required String fingerprint,
}) {
  final host = port == 22 ? hostname : '$hostname:$port';
  final oldFp = formatMd5FingerprintFromStored(existing.fingerprint);
  final newFp = formatMd5FingerprintFromStored(fingerprint);

  return showDialog<bool>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 420,
        child: PopupSurface(color: FrostedGlassStyle.dialogFill, child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Host Key Changed',
                style: TextStyle(
                  color: Color(0xFFFF6E67),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'WARNING: The remote host key for $host has changed. '
                'This may indicate a man-in-the-middle attack.\n'
                'Only continue if you have verified through another channel '
                'that this change is expected (e.g. the server was '
                'reinstalled or its key was rotated).',
                style: const TextStyle(
                  color: Color(0xFF8E8E8E),
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              const Text('Known fingerprint',
                  style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 11)),
              const SizedBox(height: 6),
              _FingerprintBlock(
                keyType: existing.keyType,
                fingerprint: oldFp,
              ),
              const SizedBox(height: 12),
              const Text('Received fingerprint',
                  style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 11)),
              const SizedBox(height: 6),
              _FingerprintBlock(keyType: keyType, fingerprint: newFp),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel',
                        style: TextStyle(color: Color(0xFF8E8E8E))),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6E67),
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Update Key and Connect'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Confirming replaces the fingerprint in '
                '~/.ssterm/known_hosts.json only. ~/.ssh/known_hosts is '
                'not modified.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 10),
              ),
            ],
          ),
        )),    // PopupSurface + Padding
      ),       // SizedBox
    ),         // Dialog
  ).then((v) => v ?? false);
}
```

（`formatMd5FingerprintFromStored` 和 `_FingerprintBlock` 保持不变，无需改动。）

- [ ] **Step 2: 修改 `host_key_verifier.dart` 的冲突分支**

在 `lib/services/host_key_verifier.dart` 里，把：

```dart
    if (conflict != null) {
      if (!context.mounted) return false;
      await showHostKeyChangedDialog(
        context,
        hostname: hostname,
        port: port,
        existing: conflict,
        keyType: keyType,
        fingerprint: fp,
      );
      return false;
    }
```

改成：

```dart
    if (conflict != null) {
      if (!context.mounted) return false;
      final updated = await showHostKeyChangedDialog(
        context,
        hostname: hostname,
        port: port,
        existing: conflict,
        keyType: keyType,
        fingerprint: fp,
      );
      if (updated) {
        await TrustedHostKeys.trust(hostname, port, keyType, fp);
      }
      return updated;
    }
```

- [ ] **Step 3: 静态分析确认没有类型错误**

Run: `flutter analyze lib/dialogs/host_key_dialog.dart lib/services/host_key_verifier.dart`
Expected: `No issues found!`

- [ ] **Step 4: 跑现有测试套件确认没有回归**

Run: `flutter test`
Expected: 所有既有测试（含 Task 1 新增的 `known_hosts_store_test.dart`）全部 PASS，无编译错误。

- [ ] **Step 5: 手动验证确认/取消两条路径**

因为这个弹窗的交互没有对应的自动化 widget test（按设计文档约定，UI 层用手动验证），在本地跑一次 app 走查：

1. 用 ssterm 连接一台已经在 `~/.ssterm/known_hosts.json` 里存了指纹的主机，确认能正常连上（不弹窗）。
2. 手动编辑 `~/.ssterm/known_hosts.json`，把该主机的 `fingerprint` 字段改成一个假值（制造冲突）。
3. 重新连接同一台主机：应弹出红色 "Host Key Changed" 警告，展示 Known/Received 两个指纹块。
4. 点击 **Cancel**：连接应中止（tab 显示连接失败/取消），且 `~/.ssterm/known_hosts.json` 里的指纹保持被人为改过的假值不变。
5. 重新连接，这次点击 **Update Key and Connect**：连接应成功建立，且 `~/.ssterm/known_hosts.json` 里该主机的 `fingerprint` 已经被替换成真实的新指纹（不再是假值，且只有一条记录，没有重复）。

确认以上 5 步行为符合预期后再进入下一步。

- [ ] **Step 6: Commit**

```bash
git add lib/dialogs/host_key_dialog.dart lib/services/host_key_verifier.dart
git commit -m "$(cat <<'EOF'
Let users confirm and auto-trust a changed SSH host key fingerprint

showHostKeyChangedDialog now returns a bool instead of always aborting
the connection. Confirming replaces the stored fingerprint in
ssterm's own known_hosts.json via the existing TrustedHostKeys.trust
and lets the connection proceed; canceling keeps today's abort
behavior. ~/.ssh/known_hosts is intentionally left untouched — dartssh2
only exposes the MD5 fingerprint, not the raw key bytes needed to
write a valid known_hosts line.
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** 设计文档三条改动点（verifier 流程、dialog UI/签名、`trust()` 替换行为的单元测试）分别对应 Task 2/Step2、Task 2/Step1、Task 1——全部有对应任务。"不修改系统级 known_hosts" 的范围边界写进了 Global Constraints 和 Task 2 的弹窗文案里。
- **占位符检查：** 未发现 TBD/TODO 或"类似 Task N"这类占位描述；两个任务的代码块都是可直接落地的完整内容。
- **类型一致性：** `showHostKeyChangedDialog` 返回类型在 Task 2 的签名（`Future<bool>`）和消费点（`host_key_verifier.dart` 里的 `final updated = await showHostKeyChangedDialog(...)`）一致；`KnownHostsStore.debugDirOverride` 的类型（`static String?`）在 Task 1 的定义和测试里的赋值/置空一致。
