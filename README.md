# PasteLink · 跨设备通用剪贴板 (iPhone ↔ Windows)

[![Release](https://img.shields.io/github/v/release/scc888/PasteLink?color=blue&label=Release)](https://github.com/scc888/PasteLink/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20iOS-lightgrey.svg)]()
[![Pure BLE 5.0](https://img.shields.io/badge/Channel-Pure%20BLE%205.0-blueviolet.svg)]()
[![End-to-End Encrypted](https://img.shields.io/badge/Security-AES--256--GCM-success.svg)]()

> **极简、极速、无云端依赖（Local-First）的 iPhone 与 Windows 跨端通用剪贴板。**  
> 电脑端 `100% 无感`（Ctrl+C 自动同步 / 自动写剪贴板），手机端 `最多一次操作`（轻点背面 / Action Button / 灵动岛 / 快捷指令一键直达）。
> 现已全面支持 **纯蓝牙无损图片** 与 **长文本/代码/URL** 双向同步！

---

## 🌟 核心能力与最新特性

### 1. 🖼️ 双向无损图片同步（Lossless Image Sync）
- **0 压缩无损画质**：Windows 截屏/位图复制直接使用纯内存无损 PNG 编码封装；iPhone 截屏与相册图片无压缩直传，拒绝模糊与 JPEG 伪影；
- **纯蓝牙 BLE 传输**：基于低功耗蓝牙 5.0 GATT 通道传输，**彻底摆脱局域网、同一 Wi-Fi 或外网服务器依赖**；
- **`PLKI` 二进制封包**：避免 Base64 膨胀（较文本编码节省 33.3% 空中带宽），采用端到端 AES-256-GCM 密文封包；
- **双端系统剪贴板原生直写**：iPhone 传来图片后 Windows 自动写入位图剪贴板，按 <kbd>Ctrl</kbd> + <kbd>V</kbd> 即可直接粘贴原图；电脑截图传至 iPhone 后自动写入 `UIPasteboard.general.image`，长按即可粘贴；
- **大图与相册一键保存**：卡片支持缩略图与尺寸标记（如 `1920×1080`），支持双击查看大图、下载 PNG 文件或在手机端“一键保存到系统相册”。

### 2. ⚡ 实时传输抽屉（Transfer Drawer）与大包分片协议
- **10 字节分片包头**：采用 `[PLKC] + [msg_id] + [total_chunks(2B)] + [chunk_index(2B)] + [flags]` 协议头，理论最高支持 30MB 载荷传输；
- **动态进度抽屉**：大数据/图片传输时，Windows 桌面浮窗自动展开抽屉，实时显示传输百分比、分片进度条与瞬时速率；
- **iOS 后台防中断保活**：通过 `beginBackgroundTask` 申请后台临时保活，防止在传输中切换 App 被 iOS 挂起中断。

### 3. 🔐 端到端零信任加密（Zero-Trust AES-256-GCM）
- **动态 PIN 码密钥派生**：基于电脑端生成的 6 位动态 PIN 码通过 SHA-256 派生 256 位对称密钥；
- **蓝牙空口全量加密**：所有文本与图像切片均经过 AES-256-GCM 封装（带 12 字节独占 Nonce 与 16 字节认证 Tag），杜绝无线嗅探与重放攻击；
- **SHA-256 双向防回环去重**：双端维护指纹循环队列，彻底防止 `Win → iPhone → Win` 的无限相互广播。

### 4. 🛡️ 密码管理器智能避让（Privacy First）
- 深度集成 Win32 底层格式过滤，自动识别 1Password、Bitwarden、KeePass 等密码管理器的 `Clipboard Viewer Ignore` 敏感标记；
- 复制密码时自动熔断拦截，不向外广播，不计入历史流水。

### 5. 💻 Windows 桌面端体验（Fluent 2.0 风格）
- **系统托盘静默驻留**：不抢占工作区焦点，支持开机静默自启动；
- **全局呼出热键**：按 <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>V</kbd> 快速呼出/收起右下角磨砂玻璃浮窗；
- **键盘流极速操作**：支持按 <kbd>↑</kbd> <kbd>↓</kbd> 快速切换条目，按 <kbd>Enter</kbd> 一键写入系统剪贴板，按 <kbd>Esc</kbd> 快速关闭；
- **外观与主题流转**：无缝支持深色模式、浅色模式与跟随 Windows 系统外观自动切换；
- **置顶收藏与历史管理**：支持单条置顶、单条删除、全量清空（保留收藏）。

### 6. 📱 深度融入 iOS 生态与硬件交互
- **Action Button (操作按钮)**：iPhone 15/16 Pro 侧边物理按键长按，瞬间推拉剪贴板；
- **轻点背面 (Back Tap)**：敲击手机背面两下，盲操将当前照片或文字瞬间推送到电脑；
- **灵动岛 / 实时活动 (Live Activity)**：电脑按下复制后，手机灵动岛与锁屏实时弹出提示；
- **桌面与锁屏小组件 (WidgetKit)**：支持小组件原地 Intent 执行，一键推拉；
- **iOS 18 控制中心小组件**：下拉控制中心随时一键推送到电脑。

---

## 🏗️ 双端工程架构

```
PasteLink/
├── windows/
│   ├── pastelink-desktop/        # [生产级客户端] Tauri 2.0 + Rust + React 19 + TypeScript
│   │   ├── src-tauri/            # Rust 核心中枢
│   │   │   ├── Cargo.toml        # 依赖配置 (image, base64, aes-gcm, windows-rs)
│   │   │   └── src/
│   │   │       ├── core/
│   │   │       │   ├── ble.rs        # BLE GATT Peripheral Server (Notify & WriteRequested)
│   │   │       │   ├── clipboard.rs  # 双通道剪贴板监听 (Bitmap & Text 轮询监听)
│   │   │       │   ├── crypto.rs     # 二进制/文本 AES-256-GCM 加解密驱动
│   │   │       │   ├── protocol.rs   # 10 字节分片协议、PLKI 图像包装、类型识别
│   │   │       │   └── state.rs      # AppState 状态机与配置持久化
│   │   │       └── lib.rs            # Tauri 命令与事件路由中心
│   │   └── src/                  # Fluent 2 现代托盘浮窗前端
│   │       ├── App.tsx           # 主窗口、分片进度抽屉、多态卡片视口
│   │       ├── App.css           # Fluent Design 设计系统与自适应主题
│   │       └── types.ts          # 跨端数据契约与接口定义
│   └── pastelink-demo/           # CLI 概念验证原型 (保留归档)
│
├── ios/
│   ├── PasteLinkApp/             # [生产级客户端] 纯正 iOS 现代消费级 App
│   │   ├── PasteLink/            # 主 App 源码
│   │   │   ├── App/              # 生命周期与外部 URL 调度 (PasteLinkApp.swift)
│   │   │   ├── Views/            # 卡片流 (ClipboardFeedView)、卡片 (ClipboardCardView)、设置中心
│   │   │   ├── Core/             # BLE 驱动 (BluetoothManager)、AES 加密 (CryptoEngine)、存储 (PasteLinkStore)
│   │   │   ├── Intents/          # App Intents / Shortcuts / 灵动岛属性
│   │   │   └── Assets.xcassets/  # 高清应用图标
│   │   ├── PasteLinkWidget/      # 桌面/锁屏/控制中心小组件
│   │   └── PasteLink.xcodeproj/  # 独立生产级 Xcode 工程
│   └── PasteLinkDemo/            # MVP 验证工程 (保留归档)
│
└── docs/                         # 技术方案与设计分析规范
```

---

## 🚀 快速上手指南

### 1. Windows 客户端

* **直接运行绿色便携版 (无需配置环境)**：
  - 下载直接运行：[`release/PasteLink_Portable_x64.exe`](file:///D:/PasteLink/release/PasteLink_Portable_x64.exe)

* **标准安装包安装**：
  - 运行安装程序：[`release/PasteLink_1.0.0_Windows_x64_Setup.exe`](file:///D:/PasteLink/release/PasteLink_1.0.0_Windows_x64_Setup.exe) (仅 2.5MB)
  - 或使用 MSI 安装包：[`release/PasteLink_1.0.0_Windows_x64.msi`](file:///D:/PasteLink/release/PasteLink_1.0.0_Windows_x64.msi)

* **本地源码开发与构建**：
  ```powershell
  cd windows/pastelink-desktop
  npm install
  npm run tauri dev
  ```

---

### 2. iOS 客户端

1. 使用 Mac 打开 Xcode 项目：[`ios/PasteLinkApp/PasteLink.xcodeproj`](file:///D:/PasteLink/ios/PasteLinkApp/PasteLink.xcodeproj)；
2. 在 **Signing & Capabilities** 中选择您的个人开发者签名 Team；
3. 将 iPhone 接入电脑，在 Xcode 顶部选择您的真机设备，点击 **Run** 即可编译安装；
4. 首次打开 App，手机会自动扫描附近的 Windows 电脑，在弹窗中输入电脑托盘浮窗显示的 6 位配对 PIN 码即可完成端到端密钥绑定。

---

## ⌨️ 常用交互手势与快捷操作

| 场景 | 电脑端操作 | 手机端响应 / 操作 |
| :--- | :--- | :--- |
| **电脑复制文字/图片至手机** | 按 <kbd>Ctrl</kbd> + <kbd>C</kbd> 复制内容 | 手机自动同步入库，剪贴板立即可贴，灵动岛弹出提示 |
| **手机复制文字/图片至电脑** | 电脑自动完成接收并写入系统剪贴板，按 <kbd>Ctrl</kbd> + <kbd>V</kbd> 粘贴 | 拷贝照片或文本后，打开 App 点击顶部一键推送，或轻敲手机背面 2 下 |
| **快速唤出/隐藏电脑浮窗** | 按 <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>V</kbd> | - |
| **电脑键盘快速选择历史** | 按 <kbd>↑</kbd> <kbd>↓</kbd> 选择条目，按 <kbd>Enter</kbd> 快速复制 | - |
| **大图查看与另存** | 双击图片卡片弹出大图查看，支持一键下载 PNG | 卡片支持“保存到系统相册”与系统级原生分享 |

---

## 📄 开源许可证

本项目基于 [MIT License](file:///D:/PasteLink/LICENSE) 协议开源。
欢迎提交 Issue 与 Pull Request！

