# 代码变更与质检报告：PasteLink 使用体验修复

日期：2026-10-29。工作区：`D:\PasteLink`，分支：`feature/lan-sync`。

本轮基于任务开始时的未提交工作继续修改，保留既有迁移、连接、剪贴板修复及安装包。未提交 Git、未发布、未覆盖 `release/` 中的程序。以下结论分为自动化验证和 iOS 源码静态验证，不代表已完成真机或界面截图审查。

## 1. 变更范围与目标

| 使用步骤 | 发现的问题与原行为 | 本轮修正 | 验证状态 |
| --- | --- | --- | --- |
| 1. 输入/修改配对码 | iOS 在握手验证前保存候选码；输入错误会覆盖原有效密钥；打开弹窗预填也可能自动发起验证 | 改为明确点击确认；仅成功握手保存；只接受 ASCII 数字；验证时禁用编辑与关闭 | iOS 静态检查 |
| 2. 失败后重试 | 上一轮握手的延迟超时可能终结下一轮请求；网络超时被误报成“配对码错误” | 超时按 challenge ID 匹配；防止并发覆盖 continuation；区分超时与明确拒绝 | iOS 静态检查 |
| 3. 解除绑定 | 清空 PIN 后仍可能从 lastEnteredPIN 恢复旧码；在途 WLAN 探活也可能恢复连接标志 | 空 PIN 明确保留解绑含义，清除记忆码；解绑立即关闭 WLAN 可用状态；探活成功回写前核对当前 PIN | iOS 静态检查 |
| 4. 长期使用与收藏 | Windows 在容量满时直接删除最旧项，收藏也会丢失；重复内容会失去收藏标志；前端另行截断为 50 条；iOS 收藏挤占普通记录配额 | 双端均按“普通记录配额 + 保留全部收藏”管理；Windows 前后端统一 30 条普通记录；重复内容继承收藏；取消收藏重新执行配额；iOS 所有写入入口统一淘汰及图片清理 | Windows Rust/前端回归通过；iOS 静态检查 |
| 5. 搜索与键盘操作 | 中文候选确认、按钮 Enter、组合键被全局历史键盘逻辑截获；删除后选择越界；选中项可能滚出视口；首尾空格导致漏查 | 排除 IME、原生控件、修饰键和已消费事件；选择限界并滚动可见；搜索统一 trim；Tab 可操作设置开关；弹窗管理焦点与取消/关闭恢复 | 7 项前端回归；TypeScript 构建；焦点部分静态复核 |
| 6. 复制图片与查看详情 | Windows 图片复制失败会退回复制图片描述并提示成功；iOS 缺原图仍显示“已复制”，且可能使用降采样缩略图 | 失败明确提示并保留界面/详情；iOS 仅成功复制原文件后显示勾选；不把文字描述或缩略图冒充原图 | Windows 构建；iOS 调用链静态检查 |
| 7. 分享/保存图片 | iOS 分享的是 `[图片]` 描述文字；保存相册无结果回调且缺权限说明，存在系统终止风险；原图缺失可能改存缩略图；预览加载失败一直转圈 | 分享原图文件 URL；原图缺失禁用分享并提示；PhotoKit 申请仅添加权限并保存原 PNG 数据，反馈成功/失败/拒绝，防止重复保存；预览失败显示说明 | Apple API 核对、plist 解析与 Target 静态检查；需真机验证 |
| 8. 清空历史 | iOS 首页有确认，设置页却直接清空；“清空所有”文案与保留收藏逻辑不符 | 设置页也确认并展示普通记录数量；统一保留收藏文案；只有收藏时禁用无效清空 | iOS 静态检查 |
| 9. 重置电脑配对码 | Windows 刷新图标直接使手机原配对码失效，没有解释后果 | 增加明确的影响说明与确认，默认聚焦取消；重置期间防重复操作；失败可见；成功提示手机重新配对 | TypeScript 构建、静态复核 |
| 10. 理解状态和失败 | 多项操作失败只写控制台；空分类显示首次连接指南；手机“复制即可自动双向同步”与实际流程不符；设置页把 WLAN 连接说成离线；“断开”实际只断开蓝牙 | 补失败提示与可读状态通知；分类空态可返回全部；明确手机复制后需发送；分别标明 WLAN/蓝牙；按钮命名“断开蓝牙”；快捷键显示完整 Ctrl+Shift+V；避免已连接蓝牙但未配对被称为信任设备 | Windows 构建、前端回归、双端源码检查 |

Windows 保留单击快速复制，以已有的“查看全文详情”按钮作为详情入口，移除与单击后自动收起相冲突的双击文案及事件。

## 2. 文件与关键技术改动

| 文件（相对项目根目录） | 职责 |
| --- | --- |
| `windows/pastelink-desktop/src-tauri/src/core/state.rs` | 保留收藏、按非收藏配额淘汰、重复条目继承收藏、取消收藏后裁剪；新增 4 项 Rust 回归用例 |
| `windows/pastelink-desktop/src/history.ts`（新增） | 前端历史合并/筛选/配额与键盘事件适用范围，供真实主界面和回归测试共用 |
| `windows/pastelink-desktop/src/App.tsx` | 接入历史逻辑，键盘边界、选中项、错误反馈、重置确认、可访问设置开关、弹窗焦点与准确引导 |
| `windows/pastelink-desktop/src/App.css` | 键盘焦点可见，选中/聚焦卡片显示动作条，原生开关尺寸与禁用反馈 |
| `windows/pastelink-desktop/tests/history.test.mjs`（新增） | Node 内置测试执行真实 TypeScript 辅助逻辑，覆盖收藏、去重、容量、搜索、筛选、IME 与控件边界 |
| `windows/pastelink-desktop/package.json` | 添加可在当前 Windows/Node 20 环境执行的 `npm test`，无需增加依赖 |
| `ios/PasteLinkApp/PasteLink/Core/PasteLinkStore.swift` | 已验证 PIN 的存取和解除绑定；统一普通历史配额与图片淘汰清理 |
| `ios/PasteLinkApp/PasteLink/Core/BluetoothManager.swift` | PIN 输入校验、并发握手保护、超时归属、准确失败原因；候选失败不直接替换原信任状态 |
| `ios/PasteLinkApp/PasteLink/Core/LANManager.swift` | 使用同步保存的 PIN 构造探活证明，拒绝无配对探活与过期成功回写 |
| `ios/PasteLinkApp/PasteLink/Views/PairingSheet.swift` | 明确确认、验证时交互隔离、取消验证前写入候选 PIN |
| `ios/PasteLinkApp/PasteLink/Views/SettingsView.swift` | 清空确认、WLAN 状态、未配对提示、解绑、通信说明 |
| `ios/PasteLinkApp/PasteLink/Views/ClipboardFeedView.swift` | 复制成功返回 Bool、原图缺失提示、发送中而非已送达文案 |
| `ios/PasteLinkApp/PasteLink/Views/ClipboardCardView.swift` | 复制回调契约，原图分享，Photos 保存与结果反馈，缺失预览终态 |
| `ios/PasteLinkApp/PasteLink/Views/DeviceBannerCard.swift` | 明确“断开蓝牙”不会关闭 WLAN 通道 |
| `ios/PasteLinkApp/PasteLink/Info.plist` | 添加 `NSPhotoLibraryAddUsageDescription` |

## 3. 自检与静态分析结果

- **Target 隔离：** 检查 `project.pbxproj` 中 `80010001`（Main App Sources）与 `80020001`（Widget Sources）。改动的 Views、BluetoothManager、LANManager 及新 Photos 调用仅属于 Main App；Store 仍是 App/Widget 共享源文件，没有引入 `UIApplication.shared`、BluetoothManager、LANManager 或 Photos 依赖。
- **受限 API：** 共享 Store、CryptoEngine、PasteIntents、ActivityAttributes 中未发现 `UIApplication.shared`。本轮没有在 Extension 中增加主 App 限制 API。
- **Intents/Controls：** 本轮未改 AppIntent / LiveActivityIntent 声明或参数；核对现有 `Button(intent:)`、`ControlWidgetButton(action:)` 标签没有受到此次修改影响。
- **照片权限：** 使用 `.addOnly`，不申请相册读取权限；`performChanges` 内新增原始 PNG 资源，所有反馈状态回主线程更新；Info.plist 经 Python `plistlib` 解析通过。API 签名与最低系统版本根据 Apple 官方文档核对，适用于工程当前 iOS 17 最低版本。
- **符号与回调：** `ClipboardCardView.onCopy` 改为 Bool，Feed 与两个 Preview 调用点均更新；Windows 新辅助函数已实际接入 App.tsx，TypeScript 严格构建通过。
- **UUID：** Swift 与 Rust 的服务、Notify、Write UUID 逐一转换比对相同：`D7E5A001/002/003-7C8B-4F9E-B8A3-2C1D4E5F6A7B`。
- **分片与序列化：** 保留 `PLKC` 的 10 字节包头、最多 480 字节分片载荷，以及 `PLKI` 的图片封装；未修改大小端、AES-GCM 格式或传输序列化。Rust 原有分片/图片/加解密测试通过。
- **16KB 规则口径：** 当前 BLE 单分片最多 490 字节，低于 16KiB；当前已有整条加密消息的发送上限是 10MiB，不是 16KiB。Windows LAN 中的 16384 检查是 HTTP 头缓冲限制。需要区分“单分片”和“完整消息”，本轮没有把大图功能收缩为 16KB，亦未声称整条消息满足该上限。
- **差异检查：** 本轮改动文件执行 `git diff --check -- <文件列表>` 通过；Git 的 LF/CRLF 转换提醒属于行尾提示。提交前清理了 `autostart.rs` 多余的文件末尾空行，不改变其逻辑。
- **独立只读复核：** 复核曾发现“弹窗关闭后搜索自动聚焦覆盖原位置”并已修正；主要改动及后续图片流程单独复核，结论和边界见下方验证记录。

相关 Apple 依据：[ShareLink](https://developer.apple.com/documentation/swiftui/sharelink)、[仅添加照片权限说明键](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryaddusagedescription)、[requestAuthorization(for:handler:)](https://developer.apple.com/documentation/photos/phphotolibrary/requestauthorization(for:handler:))、[forAsset()](https://developer.apple.com/documentation/photos/phassetcreationrequest/forasset())、[addResource(with:data:options:)](https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource(with:data:options:))。

## 4. 测试执行状态

| 检查 | 命令/方法 | 结果 |
| --- | --- | --- |
| 基线 Rust | `cargo test --manifest-path windows/pastelink-desktop/src-tauri/Cargo.toml` | 22 通过，0 失败，1 原有 ignored |
| 缺陷复现 | 添加回归后执行 State 测试及初始前端用例 | 收藏淘汰/重复失去收藏等 3 项 Rust 用例失败；初始前端 5 项失败、1 项通过，随后修复 |
| 完整 Rust | `cargo test --manifest-path windows/pastelink-desktop/src-tauri/Cargo.toml` | 26 通过，0 失败，1 ignored；main/doc-tests 均通过 |
| 前端回归 | 在 `windows/pastelink-desktop` 执行 `npm test` | 7 通过，0 失败；测试脚本明确限制文件，避免 Node 递归扫描 Rust target |
| 生产前端 | 在同目录执行 `npm run build` | TypeScript + Vite 构建通过 |
| 静态平台契约 | Python 解析 Xcode Sources、UUID、PLKC/PLKI 和 plist；回调调用点搜索 | 通过；不等同 iOS 编译 |
| iOS 编译/测试 | 工具链探测：`swift`、`xcodebuild` 不存在 | 无法在当前 Windows 宿主运行，未声称通过 |

唯一跳过的测试为 `core::clipboard::clipboard_integration_tests::reads_current_windows_clipboard_image`，其现有定义要求用户剪贴板预先含真实图片；本轮未替换用户剪贴板去强行执行。Rust 链接器输出一条创建 lib/exp 的原有提示，不影响测试通过。

## 5. 验证边界与设备验收

- 当前没有可用的目标应用截图/交互通道，没有提供界面截图证据；布局、读屏播报和实际键盘焦点操作仍需运行应用验证。本报告是源码与测试质检，不是完整视觉或可访问性认证。
- iOS 仅完成全面的相关调用链、系统 API、Target 与逻辑静态检查。Mac 上仍需编译 Main App 和 Widget 两个 Target，并在真机验证配对错误重试、解绑后重启、BLE/WLAN 切换、保存相册首次授权/拒绝/重试、分享 PNG、原图缺失、清空后保留收藏。
- Windows 自动测试覆盖本次历史/键盘条件逻辑，不覆盖真实 BLE 适配器、手机后台保活、系统剪贴板占用和 Tauri 窗口交互。
- 本轮未重新生成 EXE/MSI/IPA，现有 `release/` 安装包不包含此次源码修复。
