# PasteLink · 跨设备通用剪贴板 (iPhone ↔ Windows)

[![Release](https://img.shields.io/github/v/release/scc888/PasteLink?color=blue&label=Release)](https://github.com/scc888/PasteLink/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20iOS-lightgrey.svg)]()

> **极简、极速、无云端依赖（Local-First）的 iPhone 与 Windows 跨端极速剪贴板。**  
> 电脑端 `100% 无感`（Ctrl+C 自动同步 / 自动写剪贴板），手机端 `最多一次操作`（Action Button / 灵动岛 / 控制中心 / 快捷指令一键直达）。

---

## 🏗️ 双端工程架构

```
PasteLink/
├── windows/
│   ├── pastelink-desktop/        # [生产级客户端] Tauri 2.0 + Rust + React/TS
│   │   ├── src-tauri/            # Rust 核心中枢 (BLE Server, Win32 密码避让, AES-256-GCM, 开机自启)
│   │   └── src/                  # Fluent 2 现代磨砂托盘浮窗 & 设置中心
│   └── pastelink-demo/           # MVP 概念验证 CLI (保留参考)
│
├── ios/
│   ├── PasteLinkApp/             # [生产级客户端] 纯正 iOS 现代 3-Tab 消费级 App
│   │   ├── PasteLink/            # 主 App 源码
│   │   │   ├── App/              # 生命周期与外部 URL 调度 (PasteLinkApp.swift)
│   │   │   ├── Views/            # 现代卡片流、设备英雄卡片、Action Button 向导、设置中心
│   │   │   ├── Core/             # BLE 驱动 (支持后台唤醒)、AES-256-GCM 加密、数据中枢
│   │   │   ├── Intents/          # App Intents / Shortcuts / 灵动岛属性
│   │   │   └── Assets.xcassets/  # 高清应用图标
│   │   ├── PasteLinkWidget/      # 桌面/锁屏/控制中心小组件
│   │   └── PasteLink.xcodeproj/  # 独立生产级 Xcode 工程
│   └── PasteLinkDemo/            # MVP 验证工程 (保留参考)
│
└── docs/                         # 技术方案与深度分析文档
```

---

## ⚡ 核心能力与特性

1. **纯 BLE 低功耗蓝牙通信 (50~100ms 极低延迟)**：
   - Windows 作为 **BLE GATT Peripheral Server**，iPhone 作为 **Central**；
   - 支持高达 **64 KB** 的 UTF-8 长文本与代码段传输；
2. **端到端 AES-256-GCM 认证加密 (Zero-Trust)**：
   - 基于 6 位动态配对 PIN 码派生 256 位对称密钥，蓝牙空口全量密文封包传输，杜绝嗅探与篡改；
3. **SHA-256 双向防回环去重 (Loopback Prevention)**：
   - 双端维护哈希环形指纹池，彻底杜绝 `Win → iPhone → Win` 的无限相互广播；
4. **隐私安全与密码管理器智能避让**：
   - 自动识别 1Password、Bitwarden、KeePass 等工具的敏感标记（`Clipboard Viewer Ignore`），遇到密码复制自动阻断对外同步；
5. **开箱即用的 Windows 桌面体验**：
   - **系统托盘静默驻留**（`skipTaskbar`），不抢夺用户工作焦点；
   - **屏幕右下角 Fluent 磨砂浮窗**（支持失焦自动隐藏、动态配对 PIN 码、一键暂停同步、开机自启动）；
6. **深度融合 iOS 系统级交互**：
   - **Action Button (操作按钮)**：侧边按一下直接完成同步；
   - **灵动岛 / 实时活动 (Live Activity)**：电脑复制后自动弹出，点击瞬间写入；
   - **iOS 18 控制中心快捷小组件**：随时下拉一键写入或推送；
   - **后台保活 (State Restoration)**：即便 App 被系统杀死，一旦收到广播仍可后台唤醒处理。

---

## 🚀 快速开始

### 1. Windows 客户端

* **绿色免安装便携版 (即点即用，推荐)**：
  - 直接运行单文件程序：[`release/PasteLink_Portable_x64.exe`](file:///D:/PasteLink/release/PasteLink_Portable_x64.exe) (零语言/运行库依赖，免安装)

* **标准安装包直装**：
  - 运行安装程序：[`release/PasteLink_1.0.0_Windows_x64_Setup.exe`](file:///D:/PasteLink/release/PasteLink_1.0.0_Windows_x64_Setup.exe) (仅 2.5MB)
  - 或使用 MSI 安装包：[`release/PasteLink_1.0.0_Windows_x64.msi`](file:///D:/PasteLink/release/PasteLink_1.0.0_Windows_x64.msi)

* **源码启动开发版**：
```powershell
cd windows/pastelink-desktop
npm run tauri dev
```

---

### 2. iOS 客户端

1. 在 Mac 上使用 Xcode 打开独立工程：[`ios/PasteLinkApp/PasteLink.xcodeproj`](file:///D:/PasteLink/ios/PasteLinkApp/PasteLink.xcodeproj)；
2. 确认已配置个人开发者签名（Signing & Capabilities）；
3. 连接 iPhone 真机，点击 **Run** 即可运行全新的消费级 PasteLink App！

---

## 📄 开源许可证

本项目基于 [MIT License](file:///D:/PasteLink/LICENSE) 协议开源。

