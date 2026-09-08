import ActivityKit
import Foundation
import os
import WidgetKit

/// 灵动岛 / 实时活动 生命周期管理器 (Demo MVP 归档工程)
///
/// 遵循极简与节能设计：
/// 1. 仅在真正与电脑建立加密就绪连接时才常驻灵动岛；
/// 2. 一旦断开连接（如离开电脑、关闭蓝牙或手动断开），灵动岛立即自动退出；
/// 3. 支持应用内开关控制、收到新剪贴板静默更新、以及用户复制后平滑收起。
///
/// @author PasteLink
/// @date 2026-09-08
final class LiveActivityManager: ObservableObject {

    static let shared = LiveActivityManager()

    private let logger = Logger(subsystem: "com.pastelink.demo", category: "LiveActivity")

    /// 当前活跃的实时活动
    private var currentActivity: Activity<PasteLinkActivityAttributes>?

    /// 用户是否在 App 内启用了灵动岛通知
    @Published var isDynamicIslandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDynamicIslandEnabled, forKey: "enableDynamicIsland")
            if !isDynamicIslandEnabled {
                endCurrentActivity()
            } else if BluetoothManager.shared.connectionState == .connected {
                startActivityIfConnected(deviceName: BluetoothManager.shared.connectedDeviceName ?? "Windows 电脑", force: true)
            }
        }
    }

    /// 复制后是否自动震动反馈
    @Published var isHapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isHapticFeedbackEnabled, forKey: "enableHapticFeedback")
        }
    }

    /// 上次用户主动通过小组件/灵动岛操作收起的时间戳 (存储在 App Group 中供跨进程读取)
    private var lastDismissedAt: Date {
        get {
            let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
            let ts = defaults.double(forKey: "lastDismissedAt")
            return ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast
        }
        set {
            let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
            defaults.set(newValue.timeIntervalSince1970, forKey: "lastDismissedAt")
        }
    }

    private init() {
        // 默认开启灵动岛与震动反馈
        self.isDynamicIslandEnabled = UserDefaults.standard.object(forKey: "enableDynamicIsland") as? Bool ?? true
        self.isHapticFeedbackEnabled = UserDefaults.standard.object(forKey: "enableHapticFeedback") as? Bool ?? true

        // 冷启动安全检查：若当前未处于真正连接状态，立即清理可能遗留的灵动岛活动
        DispatchQueue.main.async {
            if BluetoothManager.shared.connectionState != .connected {
                self.endCurrentActivity()
            }
        }
    }

    /// 真正连接上设备后，启动或同步灵动岛实时活动 (仅在连接状态有效)
    /// - Parameters:
    ///   - deviceName: 连接的目标电脑设备名
    ///   - force: 是否忽略防抖与已存在判断强行启动
    func startActivityIfConnected(deviceName: String = "Windows 电脑", force: Bool = false) {
        guard isDynamicIslandEnabled else {
            logger.info("用户已在应用内关闭灵动岛功能，跳过启动")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.warning("iOS 系统设置中未授予实时活动权限")
            return
        }
        // 核心校验：必须真正处于连接状态且认证有效
        guard force || (BluetoothManager.shared.connectionState == .connected && !BluetoothManager.shared.isAuthFailed) else {
            logger.info("未处于真正连接就绪状态，不展示灵动岛")
            return
        }
        // 配对码未配置时不提前启动
        guard !PasteLinkStore.shared.getPairingPIN().isEmpty else {
            logger.info("尚未完成配对码绑定，暂缓启动灵动岛")
            return
        }

        // 避免在用户刚刚点击灵动岛复制导致 App 激活的瞬间发生反弹
        if !force && Date().timeIntervalSince(lastDismissedAt) < 2.0 {
            logger.info("距离上次主动收起时间过短 (<2s)，忽略前台反弹请求")
            return
        }

        // 若已有活跃活动，保持引用即可
        if let existing = Activity<PasteLinkActivityAttributes>.activities.first {
            self.currentActivity = existing
            logger.info("✅ 灵动岛已有活跃实例 (\(existing.id))，保持就绪待命")
            return
        }

        // 构造初次展示内容：优先提取最新剪贴板摘要，无历史记录则显示连接就绪
        let initialText: String
        if let latest = PasteLinkStore.shared.clipboardHistory.first {
            if latest.category == "image" {
                let w = latest.width ?? 0
                let h = latest.height ?? 0
                initialText = (w > 0 && h > 0) ? "已同步来自电脑的图片 (\(w)×\(h))" : "已同步来自电脑的图片"
            } else {
                initialText = latest.content
            }
        } else {
            initialText = "PasteLink 已就绪 · 随时同步"
        }

        let preview = initialText.count > 30 ? String(initialText.prefix(30)) + "..." : initialText
        let contentState = PasteLinkActivityAttributes.ContentState(
            textPreview: preview,
            fullText: initialText,
            timestamp: Date(),
            sourceDevice: deviceName
        )

        do {
            let attributes = PasteLinkActivityAttributes(sessionName: "PasteLink")
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: contentState,
                    staleDate: Date().addingTimeInterval(3600 * 24) // 保持待命 24 小时
                ),
                pushType: nil
            )
            self.currentActivity = activity
            logger.info("🎉 [已连接电脑] 灵动岛已成功就绪常驻: \(activity.id)")
        } catch {
            logger.warning("⚠️ 启动灵动岛失败 (若处于后台则遵循 ActivityKit 规范等待前台唤起): \(error.localizedDescription)")
        }
    }

    /// 兼容旧调用接口：按当前连接状态同步灵动岛生命周期
    func ensureActivityStarted() {
        if BluetoothManager.shared.connectionState == .connected && !BluetoothManager.shared.isAuthFailed {
            startActivityIfConnected(deviceName: BluetoothManager.shared.connectedDeviceName ?? "Windows 电脑")
        } else {
            endCurrentActivity()
        }
    }

    /// 弹出或更新灵动岛 / 锁屏实时活动 (收到新内容时调用)
    func showLiveActivity(text: String, deviceName: String = "Windows 电脑", force: Bool = false) {
        guard isDynamicIslandEnabled else {
            logger.info("用户已在应用内关闭灵动岛通知，跳过弹出")
            return
        }

        // 检查系统级 ActivityKit 权限
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.warning("iOS 系统设置中未开启实时活动权限")
            return
        }

        // 仅在已连接或强制模式下处理
        guard force || (BluetoothManager.shared.connectionState == .connected && !BluetoothManager.shared.isAuthFailed) else {
            logger.warning("当前非连接就绪状态，跳过灵动岛更新")
            return
        }

        WidgetKit.WidgetCenter.shared.reloadAllTimelines()

        let preview = text.count > 30 ? String(text.prefix(30)) + "..." : text
        let contentState = PasteLinkActivityAttributes.ContentState(
            textPreview: preview,
            fullText: text,
            timestamp: Date(),
            sourceDevice: deviceName
        )

        Task {
            // 检查是否已有活跃的 PasteLink 实时活动 (后台 update 是完全被 iOS 允许的)
            if let existing = Activity<PasteLinkActivityAttributes>.activities.first {
                self.currentActivity = existing
                await existing.update(ActivityContent(
                    state: contentState,
                    staleDate: Date().addingTimeInterval(3600 * 24)
                ))
                logger.info("🔄 [后台静默更新] 灵动岛已更新: \(preview)")
            } else {
                do {
                    let attributes = PasteLinkActivityAttributes(sessionName: "PasteLink")
                    let activity = try Activity.request(
                        attributes: attributes,
                        content: ActivityContent(
                            state: contentState,
                            staleDate: Date().addingTimeInterval(3600 * 24)
                        ),
                        pushType: nil
                    )
                    self.currentActivity = activity
                    logger.info("🎉 已成功弹出灵动岛实时活动: \(activity.id)")
                } catch {
                    logger.warning("⚠️ 灵动岛未在前台预启动，后台无法新建 (打开 App 即可常驻): \(error.localizedDescription)")
                }
            }
        }
    }

    /// 关闭结束当前的实时活动 (非连接状态或用户复制后自动退出)
    func endCurrentActivity() {
        self.lastDismissedAt = Date()
        Task {
            let activities = Activity<PasteLinkActivityAttributes>.activities
            guard !activities.isEmpty else {
                self.currentActivity = nil
                return
            }
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            self.currentActivity = nil
            logger.info("🛑 灵动岛实时活动已自动退出并清除")
        }
    }
}
