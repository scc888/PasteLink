import AppIntents
import ActivityKit
import AudioToolbox
import UIKit
import UniformTypeIdentifiers
import WidgetKit

// MARK: - 错误定义

enum PasteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyClipboard
    case sendFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyClipboard:
            return "尚未收到来自 Windows 的剪贴板内容"
        case .sendFailed(let msg):
            return "发送失败: \(msg)"
        }
    }
}

// MARK: - 1. 快捷指令：获取 Windows 最新剪贴板 (Windows → iPhone 核心)

/// 获取 Windows 最新剪贴板文本或图片
///
/// 核心规范 (单一职责):
/// - 从 `group.com.pastelink.shared` 读取 `lastReceivedType` 与对应的文本或图片
/// - 通过 `ReturnsValue<IntentFile>` 返回文件/媒体给快捷指令后续动作 (由 Apple 原生“复制到剪贴板”动作真正写入系统)
/// - 同步在 MainActor 直接写入系统剪贴板双保险
/// - 不要求打开 PasteLink 主 App (openAppWhenRun = false)
///
/// @author PasteLink
/// @date 2026-09-02
struct GetWindowsClipboardIntent: AppIntent {

    static var title: LocalizedStringResource = "获取 Windows 最新剪贴板"

    static var description: IntentDescription = IntentDescription(
        "从 PasteLink 读取 Windows 最近同步的剪贴板内容（文本或图片），供快捷指令使用"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
        let type = defaults.string(forKey: "lastReceivedType") ?? "text"

        if type == "image" {
            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") else {
                throw PasteIntentError.emptyClipboard
            }
            let imgURL = containerURL.appendingPathComponent("last_received_image.png")
            guard let imgData = try? Data(contentsOf: imgURL), let image = UIImage(data: imgData) else {
                throw PasteIntentError.emptyClipboard
            }

            await MainActor.run {
                UIPasteboard.general.image = image
                UIPasteboard.general.setData(imgData, forPasteboardType: "public.png")
                AudioServicesPlaySystemSound(1519)
            }

            let file = IntentFile(data: imgData, filename: "clipboard.png", type: .png)
            return .result(value: file)
        } else {
            guard let text = defaults.string(forKey: "lastReceivedClipboard"), !text.isEmpty else {
                throw PasteIntentError.emptyClipboard
            }

            await MainActor.run {
                UIPasteboard.general.string = text
                UIPasteboard.general.setValue(text, forPasteboardType: "public.utf8-plain-text")
                AudioServicesPlaySystemSound(1519)
            }

            let textData = text.data(using: .utf8) ?? Data()
            let file = IntentFile(data: textData, filename: "clipboard.txt", type: .plainText)
            return .result(value: file)
        }
    }
}

// MARK: - 2. 快捷指令：发送到 Windows 剪贴板 (iPhone → Windows 核心)

/// 发送文本到 Windows 剪贴板
///
/// 核心规范 (单一职责):
/// - 接收上游快捷指令动作（如 Apple 原生“获取剪贴板”）传入的文本参数
/// - 通过 BLE 特征值推送到 Windows 端的 PasteLink GATT Server
/// - openAppWhenRun = false，全程无需打开 PasteLink 主 App
///
/// @author PasteLink
/// @date 2026-09-02
struct SendToWindowsIntent: AppIntent {

    static var title: LocalizedStringResource = "发送到 Windows 剪贴板"

    static var description: IntentDescription = IntentDescription(
        "将文本内容通过蓝牙推送到 Windows 剪贴板"
    )

    static var openAppWhenRun: Bool = false

    @Parameter(title: "待发送文本", description: "输入要发送到 Windows 的文字或由上一步剪贴板传入")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("发送 \(\.$text) 到 Windows 电脑")
    }

    init() {}

    init(text: String) {
        self.text = text
    }

    func perform() async throws -> some IntentResult {
        var targetText: String = text ?? ""
        var targetImageData: Data? = nil
        if targetText.isEmpty {
            await MainActor.run {
                if let img = UIPasteboard.general.image, let data = img.pngData() {
                    targetImageData = data
                } else {
                    targetText = UIPasteboard.general.string ?? ""
                }
            }
        }

        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard

        if let imgData = targetImageData,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") {
            let pendingImgURL = containerURL.appendingPathComponent("pending_send_image.png")
            try? imgData.write(to: pendingImgURL, options: .atomic)
            defaults.set("image", forKey: "pendingSendType")
            defaults.removeObject(forKey: "pendingSendToWindows")

            let notificationName = CFNotificationName("com.pastelink.sendPendingClipboard" as CFString)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                notificationName,
                nil,
                nil,
                true
            )

            await MainActor.run {
                AudioServicesPlaySystemSound(1519)
            }
            return .result()
        }

        if targetText.isEmpty {
            targetText = defaults.string(forKey: "pendingSendToWindows") ?? ""
        }

        guard !targetText.isEmpty else {
            return .result()
        }

        // 存入 App Group 跨进程共享缓存
        defaults.set("text", forKey: "pendingSendType")
        defaults.set(targetText, forKey: "pendingSendToWindows")

        // 通过 Darwin Notification 通知主 App 进程立即投递 BLE 剪贴板包
        let notificationName = CFNotificationName("com.pastelink.sendPendingClipboard" as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notificationName,
            nil,
            nil,
            true
        )

        await MainActor.run {
            AudioServicesPlaySystemSound(1519)
        }

        return .result()
    }
}

// MARK: - 3. 控制中心专属 Intents (确保完整读写剪贴板权限)

/// 控制中心一键复制 Windows 剪贴板 Intent
struct ControlCenterCopyIntent: AppIntent {

    static var title: LocalizedStringResource = "控制中心复制 Windows"

    static var description: IntentDescription = IntentDescription(
        "在控制中心一键获取 Windows 剪贴板并写入 iPhone"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
        let type = defaults.string(forKey: "lastReceivedType") ?? "text"

        if type == "image" {
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") {
                let imgURL = containerURL.appendingPathComponent("last_received_image.png")
                if let imgData = try? Data(contentsOf: imgURL), let image = UIImage(data: imgData) {
                    await MainActor.run {
                        UIPasteboard.general.image = image
                        UIPasteboard.general.setData(imgData, forPasteboardType: "public.png")
                        AudioServicesPlaySystemSound(1519)
                    }
                }
            }
            return .result()
        }

        guard let text = defaults.string(forKey: "lastReceivedClipboard"), !text.isEmpty else {
            return .result()
        }

        await MainActor.run {
            UIPasteboard.general.string = text
            UIPasteboard.general.setValue(text, forPasteboardType: "public.utf8-plain-text")
            AudioServicesPlaySystemSound(1519)
        }

        return .result()
    }
}

/// 控制中心一键推送剪贴板到 Windows Intent
struct ControlCenterPushIntent: AppIntent {

    static var title: LocalizedStringResource = "控制中心推送到 Windows"

    static var description: IntentDescription = IntentDescription(
        "在控制中心一键将 iPhone 剪贴板推送到 Windows"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        var clipText = ""
        var clipImageData: Data? = nil
        await MainActor.run {
            if let img = UIPasteboard.general.image, let data = img.pngData() {
                clipImageData = data
            } else {
                clipText = UIPasteboard.general.string ?? ""
            }
        }

        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard

        if let imgData = clipImageData,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") {
            let pendingImgURL = containerURL.appendingPathComponent("pending_send_image.png")
            try? imgData.write(to: pendingImgURL, options: .atomic)
            defaults.set("image", forKey: "pendingSendType")
            defaults.removeObject(forKey: "pendingSendToWindows")

            let notificationName = CFNotificationName("com.pastelink.sendPendingClipboard" as CFString)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                notificationName,
                nil,
                nil,
                true
            )

            await MainActor.run {
                AudioServicesPlaySystemSound(1519)
            }
            return .result()
        }

        guard !clipText.isEmpty else {
            return .result()
        }

        defaults.set("text", forKey: "pendingSendType")
        defaults.set(clipText, forKey: "pendingSendToWindows")

        // 触发 Darwin Notification 发送
        let notificationName = CFNotificationName("com.pastelink.sendPendingClipboard" as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notificationName,
            nil,
            nil,
            true
        )

        await MainActor.run {
            AudioServicesPlaySystemSound(1519)
        }

        return .result()
    }
}

// MARK: - 4. 快捷指令：直接粘贴 Windows (兼容单动作用法)

/// 快捷指令: 将 Windows 最新剪贴板写入 iPhone 系统剪贴板
struct PasteFromWindowsIntent: AppIntent {

    static var title: LocalizedStringResource = "粘贴 Windows 剪贴板"

    static var description: IntentDescription = IntentDescription(
        "将 Windows 上最近复制的内容（文本或图片）粘贴到 iPhone 剪贴板"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
        let type = defaults.string(forKey: "lastReceivedType") ?? "text"

        if type == "image" {
            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") else {
                throw PasteIntentError.emptyClipboard
            }
            let imgURL = containerURL.appendingPathComponent("last_received_image.png")
            guard let imgData = try? Data(contentsOf: imgURL), let image = UIImage(data: imgData) else {
                throw PasteIntentError.emptyClipboard
            }

            await MainActor.run {
                UIPasteboard.general.image = image
                UIPasteboard.general.setData(imgData, forPasteboardType: "public.png")
                AudioServicesPlaySystemSound(1519)
            }
            return .result()
        }

        guard let text = defaults.string(forKey: "lastReceivedClipboard"), !text.isEmpty else {
            throw PasteIntentError.emptyClipboard
        }

        await MainActor.run {
            UIPasteboard.general.string = text
            UIPasteboard.general.setValue(text, forPasteboardType: "public.utf8-plain-text")
            AudioServicesPlaySystemSound(1519)
        }

        return .result()
    }
}

// MARK: - 4. 小组件与灵动岛点击 Intent (兜底与界面触发)

/// 小组件点击复制 Intent (拉起主 App 执行以获取合法 UIPasteboard 前台写入权限)
struct CopyFromWidgetIntent: AppIntent {

    static var title: LocalizedStringResource = "复制 Windows 剪贴板"

    static var description: IntentDescription = IntentDescription(
        "从小组件中一键将 Windows 剪贴板内容写入 iPhone 剪贴板"
    )

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
        let type = defaults.string(forKey: "lastReceivedType") ?? "text"

        if type == "image" {
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") {
                let imgURL = containerURL.appendingPathComponent("last_received_image.png")
                if let imgData = try? Data(contentsOf: imgURL), let image = UIImage(data: imgData) {
                    await MainActor.run {
                        UIPasteboard.general.image = image
                        UIPasteboard.general.setData(imgData, forPasteboardType: "public.png")
                        AudioServicesPlaySystemSound(1519)
                    }

                    // 复制完成后收起灵动岛
                    for activity in Activity<PasteLinkActivityAttributes>.activities {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
            return .result()
        }

        if let text = defaults.string(forKey: "lastReceivedClipboard"), !text.isEmpty {
            await MainActor.run {
                UIPasteboard.general.string = text
                UIPasteboard.general.setValue(text, forPasteboardType: "public.utf8-plain-text")
                AudioServicesPlaySystemSound(1519)
            }

            // 复制完成后收起灵动岛
            for activity in Activity<PasteLinkActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        return .result()
    }
}

/// 小组件点击推送 Intent (拉起主 App 执行以获取合法 UIPasteboard 读取权限)
struct PushFromWidgetIntent: AppIntent {

    static var title: LocalizedStringResource = "推送到 Windows 剪贴板"

    static var description: IntentDescription = IntentDescription(
        "从小组件中一键将 iPhone 剪贴板推送到 Windows"
    )

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        var clipText = ""
        var clipImageData: Data? = nil
        await MainActor.run {
            if let img = UIPasteboard.general.image, let data = img.pngData() {
                clipImageData = data
            } else {
                clipText = UIPasteboard.general.string ?? ""
            }
        }

        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard

        if let imgData = clipImageData,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") {
            let pendingImgURL = containerURL.appendingPathComponent("pending_send_image.png")
            try? imgData.write(to: pendingImgURL, options: .atomic)
            defaults.set("image", forKey: "pendingSendType")
            defaults.removeObject(forKey: "pendingSendToWindows")

            let notificationName = CFNotificationName("com.pastelink.sendPendingClipboard" as CFString)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                notificationName,
                nil,
                nil,
                true
            )

            await MainActor.run {
                AudioServicesPlaySystemSound(1519)
            }
        } else if !clipText.isEmpty {
            defaults.set("text", forKey: "pendingSendType")
            defaults.set(clipText, forKey: "pendingSendToWindows")

            let notificationName = CFNotificationName("com.pastelink.sendPendingClipboard" as CFString)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                notificationName,
                nil,
                nil,
                true
            )

            await MainActor.run {
                AudioServicesPlaySystemSound(1519)
            }
        }
        return .result()
    }
}

/// 灵动岛点击复制 Intent
@available(iOSApplicationExtension 17.0, *)
struct CopyFromLiveActivityIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "从灵动岛复制"

    static var openAppWhenRun: Bool = true

    @Parameter(title: "待复制文本")
    var text: String?

    init() {}

    init(text: String) {
        self.text = text
    }

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
        let type = defaults.string(forKey: "lastReceivedType") ?? "text"

        if type == "image" {
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") {
                let imgURL = containerURL.appendingPathComponent("last_received_image.png")
                if let imgData = try? Data(contentsOf: imgURL), let image = UIImage(data: imgData) {
                    await MainActor.run {
                        UIPasteboard.general.image = image
                        UIPasteboard.general.setData(imgData, forPasteboardType: "public.png")
                        AudioServicesPlaySystemSound(1519)
                    }
                }
            }
        } else {
            let targetText: String
            if let t = text, !t.isEmpty {
                targetText = t
            } else {
                targetText = defaults.string(forKey: "lastReceivedClipboard") ?? ""
            }

            if !targetText.isEmpty {
                await MainActor.run {
                    UIPasteboard.general.string = targetText
                    UIPasteboard.general.setValue(targetText, forPasteboardType: "public.utf8-plain-text")
                    AudioServicesPlaySystemSound(1519)
                }
            }
        }

        // 复制成功后自动收起灵动岛
        for activity in Activity<PasteLinkActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        return .result()
    }
}

// MARK: - 6. 系统预置快捷指令提供者 (AppShortcutsProvider)

@available(iOS 16.0, iOSApplicationExtension 16.0, *)
struct PasteLinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetWindowsClipboardIntent(),
            phrases: [
                "获取 \(.applicationName) 剪贴板",
                "复制 \(.applicationName) 内容",
                "从 \(.applicationName) 同步",
                "粘贴来自 Windows 的内容"
            ],
            shortTitle: "获取 Windows 剪贴板",
            systemImageName: "arrow.down.doc.fill"
        )
        AppShortcut(
            intent: SendToWindowsIntent(),
            phrases: [
                "推送到 \(.applicationName)",
                "发送剪贴板到 \(.applicationName)",
                "同步到 Windows 电脑"
            ],
            shortTitle: "推送到 Windows",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: ControlCenterCopyIntent(),
            phrases: [
                "一键复制 \(.applicationName)",
                "用 \(.applicationName) 复制"
            ],
            shortTitle: "复制 Windows 剪贴板",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: ControlCenterPushIntent(),
            phrases: [
                "一键推送 \(.applicationName)",
                "用 \(.applicationName) 推送"
            ],
            shortTitle: "推送到 Windows",
            systemImageName: "paperplane.fill"
        )
    }
}
