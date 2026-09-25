# 课程作业桌宠

<img width="228" height="104" alt="截屏2026-09-25 10 59 22" src="https://github.com/user-attachments/assets/7ad176c1-7857-4769-b6ec-71ea272781d0" />

macOS 原生悬浮桌宠，常驻桌面角落。点击角色展开作业卡片，可以看 Canvas 作业要求并直接打开对应页面。长按头像拖动可移动桌宠。

爱音会按前台 App 记住遮挡位置。首次遇到某个 App 时先停在桌面默认位置；长按头像拖动调整位置，松手即自动保存为该 App 的记忆点，下次切回时恢复。

桌宠采用 `Sources/Resources/anon_head.png` 中的头像素材。更换外观时替换该 PNG 并保持文件名不变，再重新构建即可。移动时显示 `anon_angry.webp`；当最近的未交作业剩余提交时间不足 3 小时（含已逾期）时，切换为 `anon_tired.png` 的疲惫贴图。

应用图标使用同一张 `anon_head` 表情，图标源文件在 `Resources/AppIcon.iconset/`。

<img width="357" height="542" alt="截屏2026-09-25 11 00 44" src="https://github.com/user-attachments/assets/4ec05f4c-6cfb-4334-a54d-86940865b174" />


## 系统要求

- **macOS 14 (Sonoma) 或更新版本**。应用使用了 macOS 14 才提供的 SwiftUI API，在更早的系统上无法运行。
- Apple Silicon 和 Intel Mac 都支持：构建脚本按本机架构编译，请从源码自行构建，不要混用别人机器上编译出的二进制。
- 构建需要 Xcode Command Line Tools（`xcode-select --install`）。

## 构建和启动

在本目录运行：

```bash
./build_app.sh
open 课程作业桌宠.app
```

构建脚本会完成资源打包、`swiftc` 编译和 ad-hoc 签名（签名是通知权限正常工作所必需的）。

> **首次运行提示**：由于应用是 ad-hoc 签名（无开发者证书），如果从网上下载的压缩包解压后打开报“文件已损坏”，请在应用目录执行 `xattr -cr 课程作业桌宠.app` 后再打开。本机自行构建的产物没有这个问题。

## 功能

- 从 Canvas 的所有 active 课程同步作业标题、要求、提交状态和截止时间。
- 截止时间按上海本地时间显示，每天自动同步一次，也可随时手动同步。
- 未提交作业在截止前 24 小时、3 小时和 30 分钟安排 macOS 通知。
- 点击作业卡片可查看说明；点击“打开这份作业”跳转到 Canvas。
- 每个 App 的遮挡点独立保存为相对窗口右上角的坐标；首次遇到时使用桌面默认位置，切换离开或关闭应用时自动保存，数据保存在桌宠偏好设置中。
- 首次启动需要把Canvas许可证复制到本机 `~/Library/Application Support/课程作业桌宠/访问许可证.txt`，后续从此处读取。桌面原文件会保留。可在桌宠设置中更改 Canvas 地址和许可证路径。
- 网络暂时不可用时显示上次缓存。

作业缓存和偏好设置保存在 `~/Library/Application Support/课程作业桌宠/`。退出桌宠后不会继续运行，也不会在后台同步。

## 隐私

- Canvas 访问许可证只保存在你本机（默认 `~/Library/Application Support/课程作业桌宠/访问许可证.txt`），仓库中不包含、也不会生成任何凭证文件。
- 应用只与你配置的 Canvas 地址（默认上海交通大学 `oc.sjtu.edu.cn`，可自行修改）通信，用于读取课程和作业；除此之外不发送任何数据。
- 作业缓存、每个 App 的位置记忆都存在本机 UserDefaults 和 Application Support 目录。

## 许可

本项目未附带开源许可证，保留所有权利。
