# xterm 兼容性优化清单

基于与 iTerm2 的对比分析，记录当前 `packages/xterm` 的缺陷与缺失功能。  
分为 **Bug**（代码写错，改动小）和 **未实现**（功能缺失，需新增）两类。

---

## 一、Bug（代码写错）

### 1. SGR 冒号子参数被静默损坏
**影响**：真彩色 `38:2:r:g:b`、256色 `38:5:n`、波浪下划线 `4:3` 等现代格式全部失效。  
**现象**：`ESC[38:2:255:0:0m` 被解析成 param=38225500，命中 `unsupportedStyle`，颜色丢失。  
**根因**：`parser.dart` `_consumeCsi()` 只把分号 `;`（ASCII 59）当分隔符，冒号 `:` 不满足任何条件直接跳过，但 `param` 不重置，导致后续数字继续累积。

**文件**：`packages/xterm/lib/src/core/escape/parser.dart` 第 239 行  
**修复**：在分号处理的 `if` 前加一个同样逻辑的冒号判断（1 行）：

```dart
// 在 if (char == Ascii.semicolon) 之前加：
if (char == Ascii.colon) {
  if (hasParam) _csi.params.add(param);
  param = 0;
  hasParam = false;
  continue;
}
```

---

### 2. Focus Reporting 只存 flag，从不发出事件
**影响**：neovim 的焦点自动保存（`FocusLost` autocmd）、tmux 活动检测失效。  
**现象**：`\e[?1004h` 被正确解析，`_reportFocusMode = true`，但焦点变化时 `\e[I`（获得焦点）和 `\e[O`（失去焦点）从未写入 PTY。  
**根因**：`render.dart` `_onFocusChange()` 只调 `markNeedsPaint()`，未检查 `reportFocusMode`。

**文件**：`packages/xterm/lib/src/ui/render.dart` 第 195 行  
**修复**：在 `_onFocusChange()` 中补发事件：

```dart
void _onFocusChange() {
  if (_terminal.reportFocusMode) {
    _terminal.onOutput?.call(_focusNode.hasFocus ? '\x1b[I' : '\x1b[O');
  }
  markNeedsPaint();
}
```

---

## 二、未实现功能

### 3. DECSCUSR — 光标形状切换
**影响**：vim/neovim 在 Normal 模式（块状）和 Insert 模式（竖线）之间切换光标形状，ssterm 无响应。  
**逃逸序列**：`CSI Ps SP q`（即 `ESC [ Ps   q`，注意有空格前缀）  
**参数**：0/1=闪烁块，2=块，3=闪烁下划线，4=下划线，5=闪烁竖线，6=竖线

**现状**：  
- `TerminalCursorType` 枚举已有 block/underline/verticalBar  
- `RenderTerminal.cursorType` setter 已有，改了会触发重绘  
- `handler.dart` 接口有 `resetCursorStyle()` 但无 `setCursorType()`  
- `_csiHandlers` 表里没有 `'q'` 这个 key，escape 被 `unknownCSI` 丢弃

**需要改动**：
1. `handler.dart`：新增接口方法 `void setCursorType(TerminalCursorType type, bool blink)`
2. `terminal.dart`：实现该方法，存储到 terminal state 并 notifyListeners
3. `parser.dart`：`_csiHandlers` 表加 `'q'`，解析中间字节（空格 = 0x20），按参数调用 handler
4. `terminal_view.dart`：监听 terminal 光标类型变化，更新传给 renderer 的 `cursorType`

---

### 4. OSC 7 — 当前工作目录
**影响**：zsh/fish/bash 默认发送此序列，用于 tab 标题显示当前目录、新窗口继承路径等。  
**逃逸序列**：`OSC 7 ; file:///path ST`

**现状**：`_escHandleOSC()` 只处理 OSC 0/1/2，其余调 `unknownOSC` 丢弃。  
**需要改动**：
1. `handler.dart`：新增 `void setWorkingDirectory(String uri)`
2. `terminal.dart`：实现，存 `workingDirectory` 属性并 notifyListeners
3. `parser.dart`：OSC switch 加 case `'7'`
4. `lib/`（上层 ssterm）：监听并更新 tab 标题 / 新窗口路径

---

### 5. OSC 8 — 超链接
**影响**：`ls --hyperlink`、git log、bat 等工具输出可点击链接，目前显示为普通文本。  
**逃逸序列**：`OSC 8 ; params ; uri ST ... OSC 8 ;; ST`（开始 / 结束）

**现状**：完全未实现。需要存储层、渲染层、手势层全部新增。  
**需要改动**：
1. Cell 存储需要 URL 引用（可用 intern 表避免重复存储）
2. Renderer 渲染时对有 URL 的 cell 加下划线并存 hit-test 区域
3. `TerminalGestureHandler` 点击时查找 URL 并调用回调
4. `TerminalView` 暴露 `onUrlTap` 回调

---

### 6. OSC 52 — 剪贴板读写
**影响**：neovim `+` 寄存器、tmux OSC 52 透传在 SSH 场景下跨机器复制。  
**逃逸序列**：`OSC 52 ; c ; base64data ST`（写），`OSC 52 ; c ; ? ST`（查询）

**现状**：未实现，走 `unknownOSC`。  
**需要改动**：
1. `handler.dart`：新增 `void setClipboard(String data)` / `void requestClipboard()`
2. `terminal.dart`：`setClipboard` 调系统剪贴板；`requestClipboard` 读后 `onOutput` base64 回复
3. `parser.dart`：OSC switch 加 case `'52'`

---

### 7. OSC 133 / 633 — Shell Integration（语义提示符）
**影响**：提示符跳转（跳到上一个命令输出）、命令执行时间统计、失败命令高亮。  
**逃逸序列**：`OSC 133 ; A ST`（提示符开始）、`B`（提示符结束）、`C`（命令开始）、`D;exitcode`（命令结束）

**现状**：未实现。  
**需要改动**：需要在行级别标记语义信息（prompt/command/output 区域），上层 UI 再消费。

---

### 8. 波浪下划线 + 下划线颜色（SGR 4:3 / SGR 58）
**影响**：neovim LSP 诊断（红色波浪线标错误 / 黄色标警告）。  
**逃逸序列**：`SGR 4:3`（波浪）、`SGR 58:2:r:g:b`（下划线颜色）、`SGR 59`（重置）

**现状**：
- `parser_sgr.dart` switch 无 53（上划线）和 58（下划线颜色）
- `cell.dart` 的 8-bit 属性字段已满，无法再存下划线样式和颜色

**需要改动**（工作量较大）：
1. `cell.dart`：扩展属性存储，增加 underlineStyle（3 bit）和 underlineColor 字段
2. `parser_sgr.dart`：SGR 53（overline）、SGR 58/59（underline color）
3. `painter.dart`：按 underlineStyle 渲染不同线型（直线/波浪/点线/虚线）

---

### 9. 终端自报能力不足（Device Attributes）
**影响**：部分工具根据 DA1/DA2 返回值决定是否启用高级功能，当前报 VT102 可能导致功能降级。  
**现状**：`emitter.dart` DA1 返回 `\e[?1;2c`（VT102），DA2 返回 `\e[>0;0;0c`（完全匿名）  
**iTerm2 返回**：DA1 `\e[?1;2c` 相同，DA2 `\e[>0;95;0c`（xterm 95），包含版本号

**需要改动**：`emitter.dart` 更新 DA2 返回值以声明 xterm 兼容性。

---

## 优先级总结

| 优先级 | 项目 | 类型 | 估算工作量 |
|--------|------|------|-----------|
| 🔴 P0 | SGR 冒号子参数 | Bug | 1 行 |
| 🔴 P0 | Focus reporting 发送事件 | Bug | 5 行 |
| 🟡 P1 | DECSCUSR 光标形状 | 未实现 | ~60 行 |
| 🟡 P1 | OSC 7 当前目录 | 未实现 | ~30 行 |
| 🟡 P1 | OSC 8 超链接 | 未实现 | ~200 行 |
| 🟡 P1 | DA2 版本声明 | 未实现 | 1 行 |
| 🟢 P2 | OSC 52 剪贴板 | 未实现 | ~40 行 |
| 🟢 P2 | 波浪下划线 + 颜色 | 未实现 | ~150 行 |
| 🟢 P2 | OSC 133 Shell Integration | 未实现 | ~300 行 |
