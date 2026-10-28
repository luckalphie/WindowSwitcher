# Window Switcher

一个替换 macOS Command+Tab 的窗口切换器。它枚举屏幕上的所有普通窗口，同一应用的多个窗口会分别列出；Sheet、Dialog、SystemDialog 以及非普通层级的临时窗口会被过滤。列表显示应用图标、窗口名称和应用名称，不创建缩略图。

## 运行

```sh
swift run
```

首次运行需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许该程序。权限用于拦截 Command+Tab，并把指定窗口设为主窗口。

按住 Command 后重复按 Tab 循环选择，松开 Command 激活选择的窗口。应用以菜单栏后台进程运行，不抢占 Dock 图标。

## 打包

```sh
swift build -c release
./build-app.sh
```
