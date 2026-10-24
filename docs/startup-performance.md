# macOS 启动性能诊断（2026-10-24）

## 症状与根因

原生壁纸先出现，Flutter 标签栏和终端光标晚出现。此前的壁纸亮度交接修复解决了视觉闪烁，但不能缩短 Flutter 控件的创建时间。

测量证实有两个主要因素：

1. macOS 分支在 `runApp` 前 `await AppConfig.load()`。这包含目录查询、文件查询、读取、解析等多个步骤。在 Debug 测量中约 157–187 ms；Profile 出现过约 756 ms 的异常等待。这是整个异步读取链的墙钟时间，不能解释成磁盘实际读了这么久。分段探针发现等待会落在不同的异步步骤中，并非始终是 `readAsString`。
2. Debug 使用 JIT，标签栏与终端处于同一个 Flutter 首帧。关闭 PTY 后，第一次 BUILD 中位数约 290 ms，其中 `CompileFunction` 时间区间合并后约 233 ms；第一次 LAYOUT 约 63 ms。标签栏先执行 build 不等于已经显示，仍须等待整帧提交及光栅化。

PTY 创建不是标签栏延迟的主要原因。Conda 的 shell 初始化影响提示符就绪，是更晚的阶段。

## 对照实验

每个场景启动独立进程 3 次，打乱顺序。表中的时间为中位数，计时从进程启动到 `waitUntilFirstFrameRasterized` 回调；不包含 Flutter CLI 编译和安装时间。回调有投递开销，不等同于用户屏幕上的逐像素显示时间。首次启动冷缓存及系统调度会产生波动，不把这些小样本数字视为稳定的性能保证。

| Debug 场景 | 进程启动到首帧回调 |
| --- | ---: |
| 完整界面 | 1148 ms |
| 完整界面，禁用 PTY | 1158 ms |
| 保留真实标签栏，移除终端主体 | 1046 ms |
| 关闭辅助后台初始化 | 1116 ms |
| 同一程序与导入图，仅显示最小 Flutter 页面 | 857 ms |

禁用 PTY 没有带来显著改善。Debug 的终端模型创建约 3 ms，移除终端主体仅减少约 100 ms，剩余大部分属于首帧之前的启动及 Flutter 工作。

单独同步读取配置，虽然让 Debug 首帧提交明显提前，却没有稳定改善首帧回调，说明只移动一个 await 并不充分。结合首帧后启动辅助工作后的另一批对照如下：

| 同批对照 | 原启动顺序 | 同步配置快照 + 首帧后后台初始化 |
| --- | ---: | ---: |
| Debug：进程到首帧回调 | 1186 ms | 1130 ms |
| Debug：Dart main 到首帧提交 | 686 ms | 465 ms |
| Profile：进程到首帧回调 | 454 ms | 390 ms |

Profile 下同步读取本机约 12 KB 的配置快照及解析约 0.3 ms；Debug 约 14–15 ms。Profile 的多轮实验也有波动；这些数据支持消除首帧前的异步配置依赖，但不支持声称彻底消除了窗口到控件出现之间的间隔。

## 最终实现

- macOS 在 `runApp` 前同步读取小型本地配置快照。原生启动背景此前已读取同一文件。缺失、损坏或字段类型错误时使用默认配置；不在此路径创建目录、执行迁移或写入文件。其他平台及日常加载/保存保留异步路径。
- 首帧仍包含真实标签栏、终端视图和光标。
- 保留 `windowManager.ensureInitialized()` 在前，避免标签栏首次查询窗口状态时访问未初始化的原生窗口。
- 其余窗口设置、主机列表加载、Shell 列表刷新、MCP 和 Skills 初始化移到首帧光栅化之后。
- macOS 的 Rust core / PTY 启动等待首帧完成；标签已关闭时取消创建。

同步文件读取的范围仅限本机小型启动配置。若配置变得很大，或用户主目录位于慢速网络存储，应重新测量，考虑由原生 runner 直接提供已读快照，避免重复读取。

## 最终源码的启动复核

清理诊断探针后，使用 `flutter run -d macos --debug --trace-startup --no-pub` 复核：从 engine enter 到首帧提交约 839 ms、到首次光栅化约 1094 ms。此前同类 trace 约为 1012 / 1155 ms。这里采用 Flutter 自己的启动时间口径，与上表的进程启动口径不同；它再次说明提交时间提前较多，而实际首帧完成的改善有限。

## 复核方式与边界

```sh
flutter run -d macos --profile --trace-startup
flutter run -d macos --debug --trace-startup
flutter test test/services/startup_appearance_test.dart test/models/app_config_test.dart test/widget_test.dart
```

诊断时另用了带标记的临时构建、VM Timeline、CPU samples 和禁用 PTY/终端主体的 A/B 开关。源码中的临时探针及实验开关均已删除。12 项相关测试通过，覆盖配置快照正常恢复、缺失/损坏回退及已有壁纸交接行为。

如果要求真实标签栏与原生窗口同时出现，Flutter 标签栏天然仍需等待引擎和首帧；进一步需要评估原生 AppKit 标签栏这一架构变更。图片缓存无法消除该依赖。

参考 Flutter 官方说明：[性能分析与 Debug/JIT、Profile/AOT 的差异](https://docs.flutter.dev/perf/ui-performance)、[控制 build 成本](https://docs.flutter.dev/perf/best-practices)。

## 渲染后端 A/B 复测

此前没有切换后端，2026-10-24 补充了 Impeller 与 Skia 对照。使用 Flutter 3.47.7 的同一份最终 Debug/Profile 应用，不改源码，通过 engine switches 的 `enable-impeller=true/false` 切换。原生启动日志分别确认 `Impeller (MetalSDF)` 与 `Skia (Metal)`，没有只凭开关推断切换成功。

每个模式/后端先单独启动一次预热，再启动三个独立进程，打乱顺序。通过 VM Timeline 读取与 Flutter CLI 相同的 `FlutterEngineMainEnter`、`Widgets built first useful frame`、`Rasterized first useful frame` 事件；下面均为 engine enter 到首次光栅化的中位数，不含 CLI 构建时间。

| 模式 | Impeller | Skia |
| --- | ---: | ---: |
| Debug | 1007 ms | 1045 ms |
| Profile | 188 ms | 231 ms |

Debug 三次：Impeller 1021/1007/1000 ms；Skia 1045/833/1064 ms。Profile 三次：Impeller 187/241/188 ms；Skia 176/245/231 ms。存在调度和缓存波动，个别 Skia 启动更快，但没有稳定优势；这组数据不支持切换到 Skia 来解决标签栏延迟。保留当前 Impeller 默认后端。

这次测的是首次光栅化时间，没有测出屏幕上闪黑的持续时间，也不把两者混为同一指标。

手动复核可分别运行：

```sh
flutter run -d macos --debug --trace-startup --enable-impeller
flutter run -d macos --debug --trace-startup --no-enable-impeller
```

切换方法参考 [Flutter 官方 Impeller 文档](https://docs.flutter.dev/perf/impeller)。临时对照脚本及结果存放在 `/tmp/ssterm-renderer-audit/`；本轮没有修改默认渲染配置。
