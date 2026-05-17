# ssterm — 功能开发计划

## 总览

按优先级实现 5 个核心功能，使 ssterm 具备与 Xshell 竞争的基础能力。

| 序号 | 功能 | 依赖 |
|------|------|------|
| 1 | 端口转发（本地/远程/动态 SOCKS5） | dartssh2 forwardLocal/Remote/Dynamic |
| 2 | Jump Host / ProxyJump | dartssh2 forwardLocal 作 socket |
| 3 | 分屏（水平/垂直） | 无外部依赖 |
| 4 | 断线重连 + Keepalive | dartssh2 client.run |
| 5 | 会话日志 | dart:io IOSink |

---

## Feature 1：端口转发

### 1.1 新增 Model：`PortForwardRule`
文件：`lib/models/port_forward_rule.dart`

```dart
enum ForwardType { local, remote, dynamic_ }

class PortForwardRule {
  final ForwardType type;
  final int localPort;      // 本地监听端口（local/dynamic）
  final String remoteHost;  // 目标主机（local forward 用）
  final int remotePort;     // 目标端口（local）或服务器端口（remote）
  final bool enabled;
}
```

序列化：toJson / fromJson

### 1.2 `SshHost` 新增字段
```dart
final List<PortForwardRule> forwardRules;
```

### 1.3 `SavedHostsStore` 更新
序列化/反序列化 `forwardRules`。

### 1.4 新增 Service：`PortForwardService`
文件：`lib/services/port_forward_service.dart`

每条规则激活后持有：
- local/dynamic：`ServerSocket` 监听 + 连接循环
- remote：`SSHRemoteForward` 对象

提供 `startAll(client, rules)` / `stopAll()` 方法。

### 1.5 `_Tab` 新增字段
```dart
PortForwardService? forwardService;
```

在 `dispose()` 中调用 `forwardService?.stopAll()`。

### 1.6 `_openSshTerminal` 集成
连接成功后调用 `PortForwardService.startAll`。

### 1.7 UI：连接对话框新增"端口转发"折叠区
- 展示规则列表（类型 | 本地端口 → 远端）
- "+ 添加规则" 按钮 → 行内表单（类型下拉、端口输入）
- 删除图标
- 每条规则可启用/禁用

---

## Feature 2：Jump Host / ProxyJump

### 2.1 `SshHost` 新增字段
```dart
final SshHost? jumpHost;  // 嵌套，不支持二级跳
```

### 2.2 `SavedHostsStore` 更新
序列化 `jumpHost`（嵌套 JSON，仅 host/port/user/auth，不含 forwardRules）。

### 2.3 `ConnectResult` 新增字段
```dart
final SSHClient? jumpClient;
```

### 2.4 `ssh_connection.dart` 更新
```
若 host.jumpHost != null：
  1. 连接 jumpHost → jumpClient
  2. jumpClient.forwardLocal(host.hostname, host.port) → tunnel socket
  3. 用 tunnel socket 创建 main SSHClient
  4. ConnectResult.jumpClient = jumpClient
```

### 2.5 `_Tab` 新增字段
```dart
SSHClient? jumpClient;
```
在 `dispose()` 中关闭。

### 2.6 UI：连接对话框新增"跳板机"折叠区
- 启用开关
- 展开后：主机、端口、用户名、认证（密码/密钥）字段

---

## Feature 3：分屏

### 3.1 分屏状态（在 `_TerminalHomeState`）
```dart
bool _splitMode = false;
int _splitSecondary = 0;       // 副屏显示哪个 tab
Axis _splitAxis = Axis.horizontal;
double _splitRatio = 0.5;      // 主屏占比
```

### 3.2 `_buildBody()` 逻辑
```
if _splitMode && tabs.length >= 2:
  主屏 = _buildTabBody(_tabs[_active])
  副屏 = _buildTabBody(_tabs[_splitSecondary])
  return SplitView(primary, secondary, axis, ratio)
else:
  return IndexedStack (现有逻辑)
```

### 3.3 新增 Widget：`SplitView`
文件：`lib/widgets/split_view.dart`

- 两个子 widget + 可拖动分隔条
- 支持 Axis.horizontal / Axis.vertical
- 分隔条拖动更新 ratio

### 3.4 工具栏新增分屏按钮
- 分屏按钮（⊟ 图标）：在 CmdPickerButton 旁
- 点击后展开菜单：水平分屏 / 垂直分屏 / 关闭分屏
- 分屏时副屏默认选下一个 tab

### 3.5 副屏 Tab 选择
分屏激活时，在副屏顶部显示一个轻量 tab 选择器（水平滚动的 tab 列表）。

---

## Feature 4：断线重连 + Keepalive

### 4.1 `SshHost` 新增字段
```dart
final int keepaliveInterval;  // 秒，0=禁用，默认 0
final bool autoReconnect;     // 默认 false
```

### 4.2 `SavedHostsStore` 更新
序列化 `keepaliveInterval` / `autoReconnect`。

### 4.3 `_Tab` 新增字段
```dart
SshHost? sshProfile;          // 用于重连
bool manuallyDisconnected = false;
Timer? keepaliveTimer;
```

### 4.4 Keepalive 实现
```dart
if (profile.keepaliveInterval > 0) {
  tab.keepaliveTimer = Timer.periodic(
    Duration(seconds: profile.keepaliveInterval),
    (_) async {
      try {
        await client.run('true').timeout(Duration(seconds: 5));
      } catch (_) { /* 连接断了，等 session.done 触发 */ }
    },
  );
}
```

### 4.5 Auto-reconnect 实现
```dart
session.done.then((_) async {
  tab.keepaliveTimer?.cancel();
  if (!mounted || tab.manuallyDisconnected) return;
  terminal.write('\r\n[连接断开]\r\n');
  if (tab.sshProfile?.autoReconnect == true) {
    terminal.write('[3 秒后自动重连...]\r\n');
    await Future.delayed(Duration(seconds: 3));
    if (!mounted || tab.manuallyDisconnected) return;
    _reconnectTab(tab);
  }
});
```

### 4.6 `_closeTab` 更新
关闭标签前设 `tab.manuallyDisconnected = true` 再调 `dispose()`。

### 4.7 UI：连接对话框"高级"折叠区
- Keepalive 间隔（下拉：禁用/15s/30s/60s）
- 自动重连开关

---

## Feature 5：会话日志

### 5.1 `SshHost` 新增字段
```dart
final bool sessionLog;  // 默认 false
```

### 5.2 `SavedHostsStore` 更新
序列化 `sessionLog`。

### 5.3 新增 Service：`SessionLogger`
文件：`lib/services/session_logger.dart`

```dart
class SessionLogger {
  final IOSink _sink;
  void write(List<int> bytes);
  Future<void> close();
  static Future<SessionLogger> create(String alias);
  // 日志路径：~/.ssterm/logs/<alias>_YYYYMMDD_HHMMSS.log
}
```

写入原始字节（含 VT 转义序列，可用 cat 回放）。

### 5.4 `_OutputPipe` 更新
```dart
SessionLogger? sessionLogger;

void _flush(Duration _) {
  ...
  if (sessionLogger != null) sessionLogger!.write(bytes);
  terminal.write(utf8.decode(bytes, allowMalformed: true));
}
```

### 5.5 `_Tab` 新增字段
```dart
SessionLogger? sessionLogger;
```
在 `dispose()` 中关闭。

### 5.6 `_openSshTerminal` 集成
```dart
SessionLogger? logger;
if (r.profile.sessionLog) {
  logger = await SessionLogger.create(r.alias);
}
final pipe = _OutputPipe(terminal, sessionLogger: logger, transform: ...);
```

### 5.7 UI：连接对话框"高级"折叠区（与 Feature 4 共用）
- 会话日志开关
- 点击"查看日志目录"打开 `~/.ssterm/logs/` 文件夹

---

## 文件变更清单

### 新建
| 文件 | 用途 |
|------|------|
| `lib/models/port_forward_rule.dart` | PortForwardRule 模型 |
| `lib/services/port_forward_service.dart` | 管理活跃转发 |
| `lib/services/session_logger.dart` | 会话日志 |
| `lib/widgets/split_view.dart` | 分屏 widget |

### 修改
| 文件 | 变更 |
|------|------|
| `lib/models/ssh_host.dart` | 增加 5 个新字段 |
| `lib/models/saved_hosts_store.dart` | 序列化新字段 |
| `lib/models/connect_result.dart` | 增加 jumpClient |
| `lib/services/ssh_connection.dart` | Jump host 连接逻辑 |
| `lib/dialogs/connect_dialog.dart` | 端口转发/跳板机/高级 UI |
| `lib/main.dart` | 分屏状态、keepalive、重连、日志 |

---

## 实现顺序与注意事项

1. 先改 `SshHost` + `SavedHostsStore`（其他所有功能依赖此基础）
2. Feature 1（端口转发）：UI 最复杂，先完成 model+service，再做 UI
3. Feature 2（跳板机）：连接逻辑改动集中，风险可控
4. Feature 3（分屏）：纯 UI，不影响连接逻辑
5. Feature 4（重连+keepalive）：在 `_Tab` 层面改动
6. Feature 5（日志）：最轻量，最后实现

## 测试清单

- [ ] 本地转发：`ssh -L` 等价行为，浏览器访问 localhost:localPort 可达远端
- [ ] 远端转发：服务器端 `netstat` 可见监听端口
- [ ] 动态转发：配置系统 SOCKS5 代理后浏览器可用
- [ ] 跳板机：只有跳板机的 IP 出现在目标服务器的 last 记录
- [ ] 分屏：可同时操作两个终端，拖动分隔条，关闭分屏
- [ ] Keepalive：长时间不操作连接不断
- [ ] 自动重连：kill SSH 进程后 3 秒内自动重连
- [ ] 日志：`~/.ssterm/logs/` 下生成 .log 文件，内容可用 cat 回放
