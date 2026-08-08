# Agent 兼容 Provider 与预设模型目录设计

## 目标

扩充 Agent 可用模型厂商，同时保持协议边界清晰：第三方 Provider 只能明确选择 OpenAI-compatible 或 Claude/Anthropic-compatible 之一。应用提供热门厂商预设，也允许用户新增任意兼容端点。

## 已确认范围

- 保留现有 OpenAI、Claude、Gemini、DeepSeek 和 Ollama Provider。
- 首批 OpenAI-compatible 预设：OpenRouter、Kimi/Moonshot、阿里百炼/Qwen、GLM/智谱、Groq、Mistral、硅基流动、Together AI、Fireworks AI。
- 首批 Anthropic-compatible 预设：MiniMax；OpenRouter 的 Anthropic Messages 入口可作为单独预设。
- 新增自定义 Provider 时，用户必须在创建时选择 `OpenAI-compatible` 或 `Anthropic-compatible`。创建后协议不可在原卡片内切换；如需切换，新增另一 Provider，避免历史工具消息按错误协议续传。
- 模型列表是应用内置目录，随 SSTerm 发布更新，不在设置页面联网查询。用户可增删模型名；自定义 Provider 的模型名完全由用户填写。
- API Key 继续只存入既有安全存储；配置 JSON 仅保存 Provider 元数据。

## 设计选择

采用“协议驱动”而不是“每厂商一个 HTTP 适配器”。现有 OpenAI 和 Anthropic 调用器已经覆盖两种请求、流式事件和工具结果格式，因此预设主要是数据：稳定 ID、显示名、协议、Base URL、内置模型与上下文窗口。

第三方 Provider 增加 `protocol` 字段：

- `openAiCompatible`：走 `/chat/completions`、Bearer 鉴权、OpenAI SSE 与工具调用。
- `anthropicCompatible`：走 `/v1/messages`、`x-api-key` 鉴权、Anthropic 内容块与工具调用。
- `geminiNative` 与 `ollamaNative` 只供原有原生 Provider 使用。

现有内置 Provider 将显式标注协议，旧配置缺失该字段时由内置 ID 推导；未知旧 Provider 保守按 OpenAI-compatible 处理，以维持当前默认分发行为。

## 设置体验

Providers 区顶部新增“Add provider”。弹窗先显示预设列表和“Custom provider”。选择 Custom 后必须选择两种兼容协议之一，再填写名称、Base URL、API Key、至少一个模型名和可选上下文窗口。预设填写后可编辑 URL、模型和窗口，但不可改协议。

模型目录中，首项是当前推荐模型，供默认下拉框直接使用。发布新版本时，配置加载会把新的内置默认模型合并到已有 Provider，同时保留用户手动添加的模型和已选择的旧模型，绝不静默删除。

## Agent 运行时

运行时根据 `protocol` 分发，而不是根据厂商 ID 做特殊分支。工具定义、工具调用和工具结果均通过相应的 OpenAI 或 Anthropic 转换器。`nativeToolCalling` 对这两种兼容协议均为 true。

这使 Kimi、OpenRouter、Groq 等 OpenAI-compatible 服务立刻复用当前稳定的 Agent 工具循环；MiniMax 等 Anthropic-compatible 服务复用 Claude 的内容块和缓存语义。每个模型的上下文窗口继续进入自适应压缩预算；未填写的自定义模型回退至 32K 保守预算。

GLM 预设使用通用 OpenAI-compatible 地址 `https://open.bigmodel.cn/api/paas/v4`，内置 `glm-5.2`（1M）、`glm-5.1`（200K）与 `glm-4.7`（200K）。Coding Plan 用户可在既有 Base URL 字段改为专属 coding 地址；不为套餐额度或私有参数建立独立适配器。

## 错误与兼容性

- 新建表单在 URL、ID、模型名重复或缺失时阻止保存并给出字段级错误。
- API 4xx/5xx、流式格式错误及不支持工具调用仍以现有错误卡片呈现，不退化为终端注入。
- 不把厂商私有服务端工具自动发送给服务商；只发送 SSTerm 的本地工具定义。
- 旧配置、旧 API Key 和默认 Provider 选择保持可用。新预设会像 Ollama 一样在加载时回填。

## 测试

- Provider 协议、JSON 往返、旧 JSON 默认推导和新预设回填。
- 两种自定义协议的创建校验与配置持久化。
- OpenAI-compatible 与 Anthropic-compatible 的非流式、SSE、工具调用与工具结果续传分发。
- 内置目录合并时新模型置前、用户模型与旧默认模型保留。
- 设置页预设创建、协议不可变、自定义 Provider 必选协议与错误提示。
