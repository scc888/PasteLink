import ActivityKit
import Foundation

/// 灵动岛 / 锁屏实时活动的数据结构模型
///
/// 遵循 ActivityKit 规范，定义灵动岛和锁屏卡片在各生命周期中展示的内容。
///
/// @author PasteLink
/// @date 2026-09-01
public struct PasteLinkActivityAttributes: ActivityAttributes {

    /// 实时活动动态更新的内容状态
    public struct ContentState: Codable, Hashable {
        /// 文本预览 (用于紧凑展示)
        public var textPreview: String

        /// 完整的剪贴板文本
        public var fullText: String

        /// 收到时间
        public var timestamp: Date

        /// 来源设备名称
        public var sourceDevice: String

        public init(
            textPreview: String,
            fullText: String,
            timestamp: Date = Date(),
            sourceDevice: String = "Windows PC"
        ) {
            self.textPreview = textPreview
            self.fullText = fullText
            self.timestamp = timestamp
            self.sourceDevice = sourceDevice
        }
    }

    /// 静态属性
    public var sessionName: String

    public init(sessionName: String = "PasteLink") {
        self.sessionName = sessionName
    }
}
