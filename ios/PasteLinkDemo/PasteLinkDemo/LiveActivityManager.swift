import ActivityKit
import Foundation
import os
import WidgetKit

/// 灵动岛 / 实时活动 生命周期管理器
///
/// 支持应用内开关控制、动态弹出、更新、以及复制后自动关闭。
///
/// @author PasteLink
/// @date 2026-09-01
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
            }
        }
    }

    /// 复制后是否自动震动反馈
    @Published var isHapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isHapticFeedbackEnabled, forKey: "enableHapticFeedback")
        }
    }

    private init() {
        // 默认开启灵动岛与震动反馈
        self.isDynamicIslandEnabled = UserDefaults.standard.object(forKey: "enableDynamicIsland") as? Bool ?? true
        self.isHapticFeedbackEnabled = UserDefaults.standard.object(forKey: "enableHapticFeedback") as? Bool ?? true
    }

    /// 预启动 / 确保灵动岛实时活动已处于活跃就绪状态 (必须在前台由 App 唤起)
    func ensureActivityStarted() {
        guard isDynamicIslandEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // 检查是否已有活跃的 PasteLink 实时活动
        if Activity<PasteLinkActivityAttributes>.activities.isEmpty {
            let sharedDefaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
            let initialText = sharedDefaults.string(forKey: "lastReceivedClipboard") ?? "PasteLink 剪贴板已就绪"
            let preview = initialText.count > 30 ? String(initialText.prefix(30)) + "..." : initialText
            let contentState = PasteLinkActivityAttributes.ContentState(
                textPreview: preview,
                fullText: initialText,
                timestamp: Date(),
                sourceDevice: "Windows 电脑"
            )

            do {
                let attributes = PasteLinkActivityAttributes(sessionName: "PasteLink")
                let activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(
                        state: contentState,
                        staleDate: Date().addingTimeInterval(3600 * 24) // 保持 24 小时待命
                    ),
                    pushType: nil
                )
                self.currentActivity = activity
                logger.info("🎉 [前台预启动] 灵动岛已常驻待命: \(activity.id)")
            } catch {
                logger.error("❌ 预启动灵动岛失败: \(error.localizedDescription)")
            }
        } else {
            self.currentActivity = Activity<PasteLinkActivityAttributes>.activities.first
            logger.info("✅ 灵动岛已有活跃实例，待命中")
        }
    }

    /// 弹出或更新灵动岛 / 锁屏实时活动
    func showLiveActivity(text: String, deviceName: String = "Windows 电脑") {
        guard isDynamicIslandEnabled else {
            logger.info("用户已在应用内关闭灵动岛通知，跳过弹出")
            return
        }

        // 检查系统级 ActivityKit 权限
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.warning("iOS 系统设置中未开启实时活动权限")
            return
        }

        // 保存到共享存储
        let sharedDefaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
        sharedDefaults.set(text, forKey: "lastReceivedClipboard")
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

    /// 关闭结束当前的实时活动
    func endCurrentActivity() {
        Task {
            for activity in Activity<PasteLinkActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            self.currentActivity = nil
            logger.info("灵动岛实时活动已结束")
        }
    }
}
