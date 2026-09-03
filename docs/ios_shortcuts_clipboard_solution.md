# PasteLink 系统快捷指令双向同步方案

## 1. 背景

PasteLink 需要实现以下双向极致同步体验：

1. **Windows → iPhone (一键复制)**：Windows 复制文本后，用户在 iPhone 上触发一次快捷操作（桌面快捷指令小组件 / Action Button / 轻点背面），文本直接写入 iPhone 系统剪贴板，**全程不打开 PasteLink 主 App**，随后可在微信、Safari 等直接粘贴。
2. **iPhone → Windows (一键推送)**：iPhone 复制文本或在任意页面选中文本后，用户触发一次快捷操作，文本通过 BLE 直接发送至 Windows 并自动写入 Windows 系统剪贴板，随后在电脑端直接 `Ctrl + V` 粘贴。

当前不能让 PasteLink 的 Widget 或 Live Activity 扩展直接在后台调用 `UIPasteboard.general` 完成复制写入，真机会返回 `PBErrorDomain Code=10: Pasteboard is not available at this time`。
同理，后台静默偷读 iPhone 系统剪贴板也会受到系统权限拦截。

因此，本方案将剪贴板的**底层读写权限交给 Apple 官方的原生快捷指令系统动作**，PasteLink 自身仅负责 BLE 数据中继与 App Group 缓存。

## 2. 双向方案结论

### 2.1 Windows → iPhone (一键复制)

PasteLink 仅负责从 App Group 读取 Windows 剪贴板并返回，Apple 的“复制到剪贴板”系统动作负责真正写入 iPhone 系统剪贴板。

```text
Windows 复制文本
        ↓ (BLE)
PasteLink 接收并存入 App Group
        ↓
用户触发“PasteLink 一键复制”快捷指令 (快捷小组件 / Action Button / 轻点背面)
        ↓
PasteLink Intent 返回最新文本 (ReturnsValue<String>)
        ↓
Apple“复制到剪贴板”系统动作写入 iPhone 系统剪贴板
        ↓
用户在微信、Safari 等应用中直接粘贴
```

### 2.2 iPhone → Windows (一键推送)

Apple 的“获取剪贴板”系统动作负责合法提取当前 iPhone 剪贴板内容，PasteLink 的“发送到 Windows”Intent 负责通过 BLE 推送到电脑端。

```text
iPhone 复制文本 (微信 / Safari / 备忘录)
        ↓
用户触发“PasteLink 一键推送”快捷指令 (快捷小组件 / Action Button / 分享菜单)
        ↓
Apple“获取剪贴板”系统动作提取当前文本
        ↓
PasteLink Intent 接收文本并通过 BLE 发送到 Windows
        ↓
Windows 后台服务收到并自动写入 Windows 系统剪贴板
        ↓
Windows 端直接 Ctrl+V 粘贴
```

## 3. 快捷指令动作链组成

### 3.1 快捷指令一：`PasteLink 一键复制` (Windows → iPhone)
1. 调用 PasteLink 提供的 **“获取 Windows 最新剪贴板”** App Intent；
2. 将上一步返回的文字交给 Apple 官方的 **“复制到剪贴板”** 动作。

### 3.2 快捷指令二：`PasteLink 一键推送` (iPhone → Windows)
1. 调用 Apple 官方的 **“获取剪贴板”** 系统动作；
2. 将获取到的文本作为参数，传给 PasteLink 提供的 **“发送到 Windows 剪贴板”** App Intent。

### 3.3 PasteLink Intent 单一职责规范：
- `GetWindowsClipboardIntent`：从 `group.com.pastelink.shared` 读取并输出字符串，不调用 `UIPasteboard`，`openAppWhenRun = false`；
- `SendToWindowsIntent`：接收 `text: String?` 参数，通过 BLE 发送或暂存队列，`openAppWhenRun = false`。

## 4. 一次安装流程

iOS 不允许第三方 App 静默创建或修改用户的多步骤个人快捷指令，因此无法做到安装 PasteLink 后自动生成整条快捷指令。

可以把用户操作降到一次安装：

1. 在 PasteLink App 内提供“一键直达添加”按钮；
2. 点击按钮后打开预先制作并分享的 iCloud 快捷指令：
   * **一键复制 (Windows → iPhone)**: `https://www.icloud.com/shortcuts/2ae405888020449e9547bea26588a270`
   * **一键推送 (iPhone → Windows)**: `https://www.icloud.com/shortcuts/d23d135aac6146b1b848201c79e518e9`
3. 系统自动弹出原生“添加快捷指令”面板，用户点击一次底部的“添加快捷指令”蓝色按钮；
4. 安装完成后立即生效，无需用户手动编辑任何动作。

## 5. 后续触发入口

快捷指令安装后，可以绑定到以下系统入口：

### 5.1 快捷指令小组件

用户把“PasteLink 一键复制”放入 Apple 的快捷指令小组件。点击后，快捷指令可以在小组件中完成“获取文本 → 复制到剪贴板”，通常不打开 PasteLink。

### 5.2 Action Button

用户在系统设置中将操作按钮绑定到“PasteLink 一键复制”。之后按一次操作按钮即可复制最新的 Windows 文本。

### 5.3 轻点背面

用户可以在辅助功能设置中，将轻点背面绑定到“PasteLink 一键复制”。

### 5.4 Siri

用户也可以通过快捷指令名称或配置的语音短语运行该操作。

## 6. 与 PasteLink 自定义小组件的区别

| 对比项 | Apple 快捷指令小组件 | PasteLink 自定义小组件 |
|:---|:---|:---|
| 当前 iOS 26.5 是否可用 | 是 | 可以展示内容，但不能后台直接写系统剪贴板 |
| 谁执行复制 | Apple“复制到剪贴板”系统动作 | PasteLink App Intent |
| 是否打开 PasteLink | 通常不打开 | 直接复制失败时只能改为打开 App 后复制 |
| 是否保留 PasteLink 自定义界面 | 否 | 是 |
| 是否需要一次配置 | 需要安装快捷指令并选择到小组件 | 只需添加小组件 |

## 7. `RunSystemShortcutIntent` 的位置

`RunSystemShortcutIntent` 的作用，是让第三方自定义 Widget 按钮运行用户配置的 App Shortcut、个人快捷指令或系统动作。

它与本方案的区别是：

- 本方案使用 Apple 自己的快捷指令小组件，iOS 26.5 可以采用；
- `RunSystemShortcutIntent` 可以把入口放回 PasteLink 自定义小组件；
- Apple 当前将该 API 标注为 iOS 27.0+ Beta；
- iOS 26.5 不能使用该 API；
- 该 API 只解决普通 Widget 的快捷指令启动问题，不能解决 Live Activity/灵动岛后台复制。

因此，iOS 26.5 阶段不能把 `RunSystemShortcutIntent` 作为实现前提。

## 8. 已知限制

1. 用户仍需进行一次“添加快捷指令”操作，PasteLink 不能静默代替用户完成；
2. 主屏入口暂时是 Apple 快捷指令小组件，而不是 PasteLink 自定义小组件；
3. 锁屏状态下执行敏感交互时，系统可能要求 Face ID、Touch ID 或解锁；
4. 系统可能显示快捷指令运行进度，但不会因此打开 PasteLink；
5. 如果 App Group 中没有有效文本，Intent 应明确返回“尚未收到 Windows 剪贴板内容”，不能把空字符串写入剪贴板；
6. 灵动岛点击后无 App 打开的静默复制，在 iOS 26.5 上仍不可实现。

## 9. 验收标准

至少需要在 iOS 26.5 真机验证以下场景：

- Windows 复制普通中文、英文和链接后，PasteLink 能更新 App Group 中的最新文本；
- 从 Apple 快捷指令小组件运行后，PasteLink 主 App 不打开；
- 快捷指令执行结束后，在微信、备忘录和 Safari 中粘贴得到最新文本；
- App 被切到后台后仍能读取已经保存的最新文本；
- 没有收到过 Windows 文本时，快捷指令给出明确失败提示；
- 连续接收多条文本时，只复制最后一条；
- 锁屏、解锁和 Face ID 场景下的行为符合系统提示；
- Action Button 和轻点背面执行结果与快捷指令小组件一致。

## 10. 最终产品定义

iOS 26.5 阶段的推荐体验是：

> Windows 复制文本后，用户点击一次 Apple 快捷指令小组件或按一次 Action Button，系统将最新文本写入 iPhone 剪贴板，全程不打开 PasteLink 主 App。

PasteLink 自定义小组件和灵动岛可以继续承担内容预览、连接状态展示和使用引导，但不能宣称支持后台静默写入系统剪贴板。

## 11. 参考资料

- [Apple：在小组件和实时活动中添加交互](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Apple：App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [Apple：适合从快捷指令小组件运行的动作](https://support.apple.com/en-ie/guide/shortcuts/-apd081d9d61f/ios)
- [Apple：RunSystemShortcutIntent](https://developer.apple.com/documentation/appintents/runsystemshortcutintent)
