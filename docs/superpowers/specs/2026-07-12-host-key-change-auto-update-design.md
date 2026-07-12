# 主机密钥变化提示与自动更新 — 设计文档

日期：2026-07-12

## 背景

ssterm 已经具备主机密钥（host key）信任基础设施：

- [lib/models/known_hosts_store.dart](../../../lib/models/known_hosts_store.dart)：ssterm 自己的信任库，存储在 `~/.ssterm/known_hosts.json`，`trust()` 方法已经支持"先删除旧条目、再写入新条目"（即覆盖更新）。
- [lib/models/openssh_known_hosts.dart](../../../lib/models/openssh_known_hosts.dart)：只读解析系统级 `~/.ssh/known_hosts`（包括哈希主机名格式）。
- [lib/services/trusted_host_keys.dart](../../../lib/services/trusted_host_keys.dart)：`TrustedHostKeys` 统一查询这两个来源，ssterm 自己的库优先级更高。
- [lib/services/host_key_verifier.dart](../../../lib/services/host_key_verifier.dart)：连接时的校验入口，指纹匹配则放行；指纹不存在则弹出确认对话框首次信任；指纹冲突（变化）则弹出警告对话框。
- [lib/dialogs/host_key_dialog.dart](../../../lib/dialogs/host_key_dialog.dart)：`showHostKeyConfirmDialog`（首次信任）与 `showHostKeyChangedDialog`（密钥变化警告）两个弹窗。

**现状问题**：`showHostKeyChangedDialog` 目前只有一个"Close"按钮，返回 `Future<void>`，`host_key_verifier.dart` 收到冲突后**总是**返回 `false` 中止连接，并在文案里让用户自己去手动编辑 `~/.ssh/known_hosts` 或 `~/.ssterm/known_hosts.json` 来解决——没有一键更新的路径。

## 目标

当远程主机密钥指纹与本地已保存的不一致时：
1. 弹窗明确警告（保留现有的 MITM 警示文案和红色标题）。
2. 用户确认后，自动将新指纹写入 ssterm 自己的信任库并放行本次连接；用户取消则维持现状（中止连接）。

## 技术约束（决定了范围边界）

dartssh2 的 `onVerifyHostKey` 回调（[ssh_transport.dart:1183-1192](file:///Users/illya/.pub-cache/hosted/pub.dev/dartssh2-2.17.1/lib/src/ssh_transport.dart#L1183-L1192)）只传入主机密钥的 **MD5 摘要**，不暴露原始公钥字节，且库内部也没有公开 getter 能拿到原始 key blob。`~/.ssh/known_hosts` 的合法条目要求写入完整的 base64 公钥，仅凭 MD5 摘要无法构造。

因此本功能**不修改**系统级 `~/.ssh/known_hosts`，只更新 ssterm 自己的 `~/.ssterm/known_hosts.json`。由于 `TrustedHostKeys` 查询时 ssterm 自己的库优先于系统文件，这足以让"确认更新"对 ssterm 内的所有后续连接（无论主机是手动添加还是从 `~/.ssh/config` 导入）都生效。系统 `~/.ssh/known_hosts` 文件保持不变，供原生 `ssh` 命令等其他工具继续使用。

## 设计

### 1. `host_key_verifier.dart` 的流程改动

```
现有冲突分支：
  if (conflict != null) {
    await showHostKeyChangedDialog(...);   // Future<void>
    return false;                           // 总是拒绝
  }

改为：
  if (conflict != null) {
    if (!context.mounted) return false;
    final updated = await showHostKeyChangedDialog(...);  // Future<bool>
    if (updated) {
      await TrustedHostKeys.trust(hostname, port, keyType, fp);
    }
    return updated;
  }
```

复用首次信任分支已经在用的 `TrustedHostKeys.trust(...)`，不新增存储逻辑。

### 2. `host_key_dialog.dart` 的 UI 改动

`showHostKeyChangedDialog` 签名从 `Future<void>` 改为 `Future<bool>`。

- 标题、红色配色、"WARNING"提示语保持不变。
- 正文文案调整：说明检测到指纹不一致，如果用户已经通过其他可信渠道核实这是预期变化（例如服务器重装），可以点击更新；否则应该取消连接。去掉现有"请手动编辑文件"的措辞。
- 按钮区从单个"Close"改为两个：
  - `取消`（`TextButton`，与现有中性灰色一致），点击 `Navigator.pop(false)`。
  - `更新密钥并连接`（`ElevatedButton`，使用警示色如 `Color(0xFFFF6E67)` 系，与标题呼应，和首次信任弹窗的蓝色"Trust and Connect"形成视觉区分），点击 `Navigator.pop(true)`。
  - 单击即确认，不额外增加二次确认步骤（如勾选框），与现有首次信任弹窗的交互摩擦力保持一致。
- 底部补充一行说明文字：确认后仅更新 `~/.ssterm/known_hosts.json`，不会修改 `~/.ssh/known_hosts`。
- `barrierDismissible: false` 保持不变，避免点击遮罩误关闭。

### 3. 不在本次范围内

- 不写入/修改系统级 `~/.ssh/known_hosts`（见上方技术约束）。
- 不通过 `ssh-keyscan` 或类似手段单独抓取真实公钥来补全系统文件（用户已确认此次不做）。
- 不改变"指纹已匹配"（无冲突）时的静默放行路径。
- 不改变首次信任新主机（`showHostKeyConfirmDialog`）的现有行为。

## 影响文件

- `lib/services/host_key_verifier.dart`：冲突分支改为按对话框结果决定是否 trust + 放行。
- `lib/dialogs/host_key_dialog.dart`：`showHostKeyChangedDialog` 返回值、文案、按钮改动。

## 测试计划

- 新增/扩展 `TrustedHostKeys` 或 `KnownHostsStore` 相关单元测试：验证对已存在 host/port 调用 `trust()` 会用新指纹替换旧指纹（而不是追加两条记录），覆盖"确认更新"这条路径依赖的存储行为。
- 手动验证：连接一个已保存指纹的主机，人为修改 `~/.ssterm/known_hosts.json` 中的指纹制造冲突，确认弹窗正确显示新旧指纹，点击"取消"中止连接、点击"更新密钥并连接"后连接成功且文件里的指纹被替换为新值。
