# Window Switcher

一个替换 macOS Command+Tab 的窗口切换器。它枚举可切换的普通窗口，同一应用的多个窗口会分别列出；Sheet、Dialog、SystemDialog 以及非普通层级的临时窗口会被过滤。列表显示应用图标、窗口名称和应用名称，不创建缩略图。

## 运行

```sh
swift run
```

首次运行需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许该程序。权限用于拦截 Command+Tab，并把指定窗口设为主窗口。

按住 Command 后重复按 Tab 循环选择，松开 Command 激活选择的窗口。应用以菜单栏后台进程运行，不抢占 Dock 图标。

菜单栏中可勾选“开机自动启动”。该选项使用 macOS 的“登录项”功能；如果系统要求确认，请在“系统设置 → 通用 → 登录项”中允许 Window Switcher。

## 打包

```sh
swift build -c release
./build-app.sh
```

创建可直接拖入“应用程序”目录安装的 DMG：

```sh
./build-dmg.sh
```

本地产物统一生成在 `dist/`。
