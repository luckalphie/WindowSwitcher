# Window Switcher 代码结构

本文面向熟悉 Java 后端、刚接触 macOS Swift 的维护者，说明项目的模块边界和核心调用链。

## 项目类型

项目采用 **Swift Package Manager（SPM）**，入口是 `Package.swift`，不是传统的 `.xcodeproj` 工程。

- 命令行构建：`swift build`
- 命令行运行：`swift run`
- Xcode：直接打开 `Package.swift`

SPM 是 Apple 官方支持的项目格式。当前应用不依赖复杂的 Xcode Target、Storyboard 或资源编译配置，因此不需要为了目录结构额外创建 `.xcodeproj`。

## 目录

```text
WindowSwitcher/
├── Package.swift                         # SPM 工程定义、最低 macOS 版本
├── Info.plist                            # 应用名称、Bundle ID、版本号
├── build-app.sh                          # 构建并签名 .app，输出至 dist/
├── build-dmg.sh                          # 构建带 Applications 快捷方式的 DMG
├── Sources/WindowSwitcher/
│   ├── main.swift                        # 进程入口
│   ├── AppDelegate.swift                 # 应用生命周期、全局热键、切换会话协调
│   ├── WindowModels.swift                # 窗口 DTO 与稳定身份
│   ├── WindowCatalog.swift               # 窗口查询、过滤和 MRU 顺序
│   ├── WindowActivator.swift             # 激活指定窗口
│   └── SwitcherOverlay.swift             # SwiftUI 列表和悬浮面板
├── docs/
│   ├── architecture.md                   # 本文
│   └── releases/                         # 每个版本的 Release Notes
└── dist/                                 # 本地 .app / .dmg 产物，Git 忽略
```

## 职责映射

| Swift 文件 | 类比 Java 分层 | 职责 |
| --- | --- | --- |
| `main.swift` | `Application.main` | 创建 `NSApplication`，注册 `AppDelegate`，启动事件循环。 |
| `AppDelegate.swift` | Controller + 应用协调器 | 接收全局键盘事件，维护一次 Cmd+Tab 会话，调用查询、展示和激活能力。 |
| `WindowCatalog.swift` | 查询 Service + 内存仓储 | 通过 Accessibility API 查询普通窗口，维护 MRU（最近使用）顺序。 |
| `WindowActivator.swift` | Command Service | 将目标应用与目标窗口设置为前台和焦点。 |
| `SwitcherOverlay.swift` | View / 前端组件 | 通过 SwiftUI 渲染窗口列表，通过 `NSPanel` 显示悬浮层。 |
| `WindowModels.swift` | DTO / Value Object | 描述可切换窗口及其稳定身份。 |

## 核心调用链

```text
用户按下 Cmd
  → AppDelegate 收到 CGEvent 全局事件
  → WindowCatalog.windows() 查询并按 MRU 排序窗口
  → AppDelegate 计算初始选中项
  → 用户重复按 Tab：更新 selected
  → 超过短延迟：SwitcherOverlay 显示列表
  → 用户松开 Cmd 或鼠标点击：WindowActivator.activate()
  → WindowCatalog.markRecentlyUsed() 更新 MRU
```

`AppDelegate` 是唯一的流程协调点；其他类型不应直接互相修改状态。

菜单中的“开机自动启动”由 `SMAppService.mainApp` 管理：勾选时把当前 `.app` 注册为 macOS 登录项，取消时撤销注册。登录项状态以系统设置为准，应用不在 `UserDefaults` 中重复保存开关；菜单每次展开都会重新读取状态。

## macOS 特有概念

### AX（Accessibility）

`AXUIElement` 是 macOS 的跨进程 UI 自动化对象，可理解为“其他应用窗口的远程代理”。它用于读取窗口标题、位置、尺寸、焦点状态，并请求窗口置前。

使用前，用户必须在“系统设置 → 隐私与安全性 → 辅助功能”授权应用。

### Event Tap

`CGEvent.tapCreate` 注册系统级键盘监听，类似全局拦截器，不是普通窗口内的快捷键回调。macOS 可能因回调超时或用户输入临时禁用监听，因此 `AppDelegate` 收到 `tapDisabledByTimeout` 或 `tapDisabledByUserInput` 时会立即重新启用它。

热键回调中避免加入耗时操作；超过 100ms 的处理会记录日志，便于诊断。

### MRU 顺序

`WindowCatalog` 使用 `recentIDs` 保存最近使用窗口，数组首项即最近窗口。每次激活窗口后把它移到首位；下一次 Cmd+Tab 优先选择当前窗口的前一个最近窗口。

窗口身份不能直接依赖 Swift 中某次返回的 `AXUIElement` 包装对象。项目通过 `PID + CFHash(AXUIElement)` 生成稳定 `WindowIdentity`，并使用 `CFEqual` 精确判断是否是同一个 AX 对象，避免同一应用内同尺寸或重叠窗口被合并。

## 台前调度与多显示器

台前调度会从 Core Graphics 的可见窗口列表隐藏非活动窗口组，因此 `WindowCatalog` 以 AX 普通窗口作为统一查询源，避免开启和关闭台前调度时窗口数量变化。

多显示器场景下，窗口中心点所在的显示器被视为该窗口归属显示器；只返回鼠标所在显示器的窗口。

## 构建与分发

```sh
# 仅生成 .app
./build-app.sh

# 生成包含 Applications 快捷方式的 DMG
./build-dmg.sh
```

所有产物写入 `dist/`，不会提交到 Git。`build-app.sh` 要求本机存在固定的 `WindowSwitcher Local Signing` 签名身份，以减少辅助功能授权因 ad-hoc 签名变化而失效的概率。

当前 DMG 使用本地开发签名，尚未经过 Apple Developer ID 公证。面向普通用户分发时，应改用 Developer ID 签名并执行 Notarization，否则 Gatekeeper 可能在每次升级时显示安全提示。
