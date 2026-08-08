# Agent 面板折叠卡片左对齐设计

## 目标

让 Agent 面板中的顶层折叠卡片与消息头像、通知和状态指示器使用同一列表左边界，避免无头像卡片被错误视为 Agent 正文而额外缩进。

## 范围

仅调整 CommandResultCard 与 ToolCallCard 的外层布局包装：

- 删除 _buildAgentMessage 中两处 left: 32。
- 保留每张卡片自身的内部 padding、宽度、展开行为、颜色和边框。
- 不调整 Agent 回复正文及其内嵌的推理折叠区；该区应继续对齐到头像后的正文列。
- 不调整编辑 diff 的内部折叠或不可折叠的 MCP 结果卡。

## 验证

为消息布局提取可测试的外层 padding 常量或 widget 测试，确认命令结果与工具调用的外层左 padding 为零；运行现有 Agent 面板相关测试和完整测试套件。

