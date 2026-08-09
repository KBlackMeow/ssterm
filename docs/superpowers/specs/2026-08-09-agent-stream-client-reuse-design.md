# Agent 流式连接复用与重试设计

## 背景

当前 Agent 每次调用 `LlmService.chatStream` 都创建新的 `HttpClient`。命令执行结果加入会话后，下一轮模型请求因此重新经历 DNS、TCP 和 TLS 握手。现场表现为首轮请求稳定成功，而命令反馈后的下一轮在 DeepSeek TLS 握手阶段失败。

此外，正常完成的流没有显式关闭其客户端；只有取消回调会执行 `client.close(force: true)`。这使客户端生命周期不明确，并放大连续请求的不稳定性。

## 目标

- 同一次 Agent 任务的多个模型迭代复用一个 `HttpClient` 连接池。
- 允许 Dart 复用已成功的 keep-alive 连接、DNS 状态和 TLS session。
- 临时连接错误发生且尚未收到任何响应内容时，重建客户端并指数退避重试。
- 任务结束、失败或取消时可靠关闭客户端。
- 不因重试重复内容、工具调用或命令执行。

公网、DNS、代理和 Provider 服务属于外部依赖，本设计不承诺网络请求 100% 成功；它保证客户端生命周期正确，并针对“首轮成功、反馈后重握手失败”的模式减少不必要的新握手。

## 生命周期

每次 `_continueAgentLoop` 启动时创建一个任务级流式客户端持有者。该持有者贯穿同一 Agent generation 的全部迭代：

1. 首轮请求按需创建 `HttpClient`。
2. 命令执行结果进入 conversation history。
3. 下一轮请求复用同一客户端的连接池。
4. Provider 主动关闭连接时，由 `HttpClient` 正常建立新连接。
5. 零内容的临时连接错误发生时，强制关闭旧客户端，创建新客户端后重试。
6. Agent 任务完成、停止、出错、取消或 generation 失效时关闭持有者。

客户端持有者不能跨 Agent 任务或 generation 共享，避免取消旧任务时影响新任务，也避免 Provider 配置切换后继续使用旧连接池。

## API 边界

新增一个纯生命周期组件，例如 `AgentStreamClientSession`：

- `HttpClient get client`：返回当前客户端，必要时创建。
- `void reset()`：强制关闭当前客户端，使下一次访问创建新实例。
- `void close({bool force = false})`：幂等关闭并标记 session 不可再用。

`LlmService.chatStream` 接受外部提供的 `HttpClient`，不再隐式拥有每轮客户端。请求级取消仍可终止当前流，但不能留下未释放客户端。任务级取消通过关闭 session 强制中断活动请求。

组件通过可注入的客户端工厂测试，不依赖真实网络。

## 重试规则

最多执行三次请求，即最多两次重试：

| 失败次数 | 重试前等待 |
|---|---:|
| 1 | 500 ms |
| 2 | 1500 ms |

仅在以下条件全部满足时重试：

- 错误属于 `HttpException`、`SocketException`、`HandshakeException`、`TlsException` 或连接提前关闭。
- 尚未收到文本内容。
- 尚未收到 reasoning 内容。
- 尚未收到任何结构化工具调用。
- 当前 widget 仍 mounted。
- Agent generation 未变化。

重试前调用 session `reset()`，确保重新解析 DNS并建立新 TLS 连接。任何内容或工具调用已经到达后都不重试，避免重复模型输出或重复命令。

## 取消与错误处理

- 用户取消：强制关闭 session，立即中断当前请求。
- 正常完成：在整个 Agent 任务退出的 `finally` 中正常关闭 session。
- 临时错误且允许重试：重建客户端，不修改 conversation history。
- 最终失败：沿用当前回滚本轮临时 history 和显示错误卡片的行为。
- session 的 `close` 和 `reset` 都必须幂等，处理多条退出路径同时触发的情况。

## 日志

重试日志增加：

- 当前 attempt 和最大 attempt。
- 退避毫秒数。
- Provider id。
- 经过脱敏的 Base URL（只记录 scheme、host 和 port）。
- 异常类型与消息。

不记录 API Key、Authorization header、消息正文或命令输出。

## 测试

采用测试驱动实现：

1. 同一 session 的连续请求取得同一个客户端实例。
2. `reset` 关闭旧客户端，下一次取得新实例。
3. `close` 幂等，并禁止关闭后重新创建客户端。
4. 正常 Agent 任务退出时关闭客户端。
5. 用户取消时强制关闭客户端。
6. 零内容 TLS/Socket 错误按 500ms、1500ms 最多重试两次。
7. 文本、reasoning 或工具调用任一已经到达后不重试。
8. 重试前重建客户端。
9. 新 generation 使用新的 session，不受旧任务取消影响。
10. 现有 Agent、命令执行和 Provider 测试全部通过。

## 非目标

- 不修改命令反馈协议或风险分类。
- 不绕过 TLS 证书校验。
- 不写死 DeepSeek CDN IP 或修改系统 DNS。
- 不跨多个 Agent 任务维护全局连接池。
