import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 快捷指令跳转辅助定义 (Shortcuts URLs)

/// 快捷指令 URL 统一定义与构造器
enum PasteLinkShortcutHelper {
    /// 一键复制到 iPhone 快捷指令名称
    static let copyShortcutName = "PasteLink 一键复制"
    /// 一键推送到 Windows 快捷指令名称
    static let pushShortcutName = "PasteLink 一键推送"

    /// 一键复制 URL (快捷指令跳转)
    static var copyShortcutURL: URL {
        let encoded = copyShortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? copyShortcutName
        return URL(string: "shortcuts://run-shortcut?name=\(encoded)")!
    }

    /// 一键推送 URL (快捷指令跳转)
    static var pushShortcutURL: URL {
        let encoded = pushShortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pushShortcutName
        return URL(string: "shortcuts://run-shortcut?name=\(encoded)")!
    }
}

// MARK: - iOS 16 / 17 兼容背景修饰符

extension View {
    @ViewBuilder
    func applyWidgetContainerBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.background(Color(.secondarySystemBackground))
        }
    }
}

// MARK: - 桌面 & 锁屏 小组件 (Home & Lock Screen Widget)

struct PasteLinkWidgetEntry: TimelineEntry {
    let date: Date
    let clipboardText: String?
}

struct PasteLinkWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PasteLinkWidgetEntry {
        PasteLinkWidgetEntry(date: Date(), clipboardText: "等待接收 Windows 剪贴板...")
    }

    func getSnapshot(in context: Context, completion: @escaping (PasteLinkWidgetEntry) -> Void) {
        let text = readSharedClipboard() ?? "等待从 Windows 复制内容..."
        completion(PasteLinkWidgetEntry(date: Date(), clipboardText: text))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PasteLinkWidgetEntry>) -> Void) {
        let text = readSharedClipboard()
        let entry = PasteLinkWidgetEntry(date: Date(), clipboardText: text)
        // 采用 atEnd 策略，以便在收到新文本通知时立即刷新最新内容
        let timeline = Timeline(entries: [entry], policy: .atEnd)
        completion(timeline)
    }

    private func readSharedClipboard() -> String? {
        let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
        let type = defaults.string(forKey: "lastReceivedType") ?? "text"
        if type == "image" {
            let width = defaults.integer(forKey: "lastReceivedImageWidth")
            let height = defaults.integer(forKey: "lastReceivedImageHeight")
            if width > 0 && height > 0 {
                return "[图片] \(width) × \(height)"
            }
            return "[图片]"
        }
        return defaults.string(forKey: "lastReceivedClipboard")
    }
}

/// 桌面与锁屏小组件视图 (双向双按钮，原地 Intent 执行，零跳转)
struct PasteLinkWidgetEntryView: View {
    var entry: PasteLinkWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            // 锁屏圆形组件 (原地复制)
            Button(intent: CopyFromWidgetIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)

        case .accessoryRectangular:
            // 锁屏长条组件 (原地复制)
            Button(intent: CopyFromWidgetIntent()) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                        Text("Windows 剪贴板")
                            .font(.caption2.bold())
                    }
                    Text(entry.clipboardText ?? "暂无内容")
                        .font(.caption2)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)

        case .systemSmall:
            // 桌面小卡片 (Small): 双动作按钮 (原地 Intent 执行)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .foregroundStyle(.blue)
                    Text("PasteLink")
                        .font(.caption.weight(.bold))
                    Spacer()
                }

                Text(entry.clipboardText ?? "暂无来自 Windows 的新内容")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                HStack(spacing: 6) {
                    Button(intent: CopyFromWidgetIntent()) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down.doc.fill")
                            Text("复制")
                        }
                        .font(.caption2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Button(intent: PushFromWidgetIntent()) {
                        HStack(spacing: 2) {
                            Image(systemName: "paperplane.fill")
                            Text("推送")
                        }
                        .font(.caption2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.purple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()

        default:
            // 桌面中卡片 (Medium): 双向剪贴板看板 (原地 Intent 执行)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.blue)
                    Text("Windows 远程剪贴板")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(entry.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(entry.clipboardText ?? "等待从 Windows 复制内容...")
                    .font(.subheadline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))

                Spacer()

                HStack(spacing: 10) {
                    // 按钮 1: 一键复制 (Windows → iPhone 原地执行)
                    Button(intent: CopyFromWidgetIntent()) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc.fill")
                            Text("一键复制到 iPhone")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    // 按钮 2: 一键推送 (iPhone → Windows 原地执行)
                    Button(intent: PushFromWidgetIntent()) {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            Text("一键推送到电脑")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.purple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

// MARK: - 灵动岛 / 实时活动 视图 (Dynamic Island Widget - 原地 Intent 执行)

@available(iOSApplicationExtension 16.1, *)
struct PasteLinkLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PasteLinkActivityAttributes.self) { context in
            // 锁屏界面浮动横幅卡片
            lockScreenBanner(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开状态 (长按灵动岛时显示的大卡片)
                DynamicIslandExpandedRegion(.leading) {
                    Label("Windows", systemImage: "desktopcomputer")
                        .font(.caption2.bold())
                        .foregroundStyle(.blue)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.textPreview)
                            .font(.subheadline)
                            .lineLimit(2)
                            .padding(.horizontal, 8)

                        // 点击原地执行复制动作
                        Button(intent: CopyFromWidgetIntent()) {
                            HStack {
                                Image(systemName: "arrow.down.doc.fill")
                                Text("一键复制到 iPhone 剪贴板")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    }
                }
            } compactLeading: {
                // 灵动岛胶囊左侧
                Image(systemName: "arrow.down.doc.fill")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                // 灵动岛胶囊右侧
                Text("复制")
                    .font(.caption2.bold())
                    .foregroundStyle(.blue)
            } minimal: {
                // 多个灵动岛时的独立小圆点
                Image(systemName: "arrow.down.doc.fill")
                    .foregroundStyle(.blue)
            }
        }
    }

    /// 锁屏界面的实时活动卡片
    @available(iOSApplicationExtension 16.1, *)
    private func lockScreenBanner(context: ActivityViewContext<PasteLinkActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.blue)
                .padding(8)
                .background(Color.blue.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("来自 Windows 剪贴板")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(context.state.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(context.state.textPreview)
                    .font(.subheadline)
                    .lineLimit(1)
            }

            Spacer()

            // 点击锁屏卡片右侧按钮，原地执行复制
            Button(intent: CopyFromWidgetIntent()) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.body.bold())
                    .padding(10)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
    }
}

// MARK: - 控制中心快捷按钮组件 (iOS 18+ Control Center Widgets)

/// 控制中心: 复制 Windows 剪贴板按钮
@available(iOSApplicationExtension 18.0, *)
struct PasteLinkCopyControl: ControlWidget {
    static let kind: String = "com.pastelink.copyControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ControlCenterCopyIntent()) {
                Label("复制 Windows", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("复制 Windows 剪贴板")
        .description("在控制中心一键获取 Windows 最新剪贴板内容并写入剪贴板")
    }
}

/// 控制中心: 推送剪贴板到 Windows 按钮
@available(iOSApplicationExtension 18.0, *)
struct PasteLinkPushControl: ControlWidget {
    static let kind: String = "com.pastelink.pushControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ControlCenterPushIntent()) {
                Label("推送到 Windows", systemImage: "paperplane.fill")
            }
        }
        .displayName("推送到 Windows")
        .description("在控制中心一键将 iPhone 剪贴板推送到 Windows 电脑")
    }
}

// MARK: - 小组件包导出 (Widget Bundle @main)

@main
@available(iOSApplicationExtension 16.1, *)
struct PasteLinkWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PasteLinkHomeScreenWidget()
        PasteLinkCopyWidget()
        PasteLinkPushWidget()
        PasteLinkLiveActivityWidget()
        if #available(iOSApplicationExtension 18.0, *) {
            PasteLinkCopyControl()
            PasteLinkPushControl()
        }
    }
}

// MARK: - 1. 双向综合看板小组件 (包含复制与推送双按钮)

struct PasteLinkHomeScreenWidget: Widget {
    let kind: String = "PasteLinkHomeScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PasteLinkWidgetProvider()) { entry in
            PasteLinkWidgetEntryView(entry: entry)
                .applyWidgetContainerBackground()
        }
        .configurationDisplayName("PasteLink 双向剪贴板")
        .description("显示来自 Windows 的最新剪贴板内容，同时支持一键复制与一键推送。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

// MARK: - 2. 专属「一键复制」小组件 (Windows → iPhone)

struct PasteLinkCopyWidget: Widget {
    let kind: String = "PasteLinkCopyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PasteLinkWidgetProvider()) { entry in
            PasteLinkCopyWidgetView(entry: entry)
                .applyWidgetContainerBackground()
        }
        .configurationDisplayName("一键复制 (Windows → iPhone)")
        .description("点击直接触发快捷指令，将 Windows 剪贴板内容瞬间写入 iPhone。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

struct PasteLinkCopyWidgetView: View {
    var entry: PasteLinkWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: CopyFromWidgetIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)

        case .accessoryRectangular:
            Button(intent: CopyFromWidgetIntent()) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("一键复制 Windows", systemImage: "arrow.down.doc.fill")
                        .font(.caption2.bold())
                    Text(entry.clipboardText ?? "暂无内容")
                        .font(.caption2)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)

        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.doc.fill")
                        .foregroundStyle(.blue)
                    Text("一键复制")
                        .font(.caption.bold())
                    Spacer()
                }

                Text(entry.clipboardText ?? "暂无来自 Windows 的新内容")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Button(intent: CopyFromWidgetIntent()) {
                    Label("复制到手机", systemImage: "doc.on.clipboard.fill")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding()

        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.doc.fill")
                        .foregroundStyle(.blue)
                    Text("Windows 剪贴板一键复制")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(entry.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(entry.clipboardText ?? "等待来自 Windows 的文本...")
                    .font(.subheadline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))

                Spacer()

                Button(intent: CopyFromWidgetIntent()) {
                    Label("一键复制到 iPhone 剪贴板", systemImage: "doc.on.clipboard.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
    }
}

// MARK: - 3. 专属「一键推送」小组件 (iPhone → Windows)

struct PasteLinkPushWidget: Widget {
    let kind: String = "PasteLinkPushWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PasteLinkWidgetProvider()) { entry in
            PasteLinkPushWidgetView(entry: entry)
                .applyWidgetContainerBackground()
        }
        .configurationDisplayName("一键推送 (iPhone → Windows)")
        .description("点击直接触发快捷指令，将 iPhone 剪贴板快速推送到 Windows 电脑。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

struct PasteLinkPushWidgetView: View {
    var entry: PasteLinkWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: PushFromWidgetIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)

        case .accessoryRectangular:
            Button(intent: PushFromWidgetIntent()) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("推送到 Windows", systemImage: "paperplane.fill")
                        .font(.caption2.bold())
                    Text("点击一键将剪贴板发送给电脑")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)

        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(.purple)
                    Text("一键推送")
                        .font(.caption.bold())
                    Spacer()
                }

                Text("将当前 iPhone 剪贴板快速推送到 Windows 电脑")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Button(intent: PushFromWidgetIntent()) {
                    Label("推送到电脑", systemImage: "paperplane.fill")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.purple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding()

        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(.purple)
                    Text("推送到 Windows 电脑")
                        .font(.subheadline.bold())
                    Spacer()
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                }

                Text("点击下方按钮，将 iPhone 当前已复制的文字通过蓝牙即刻同步至 Windows 电脑剪贴板。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))

                Spacer()

                Button(intent: PushFromWidgetIntent()) {
                    Label("一键推送到 Windows 剪贴板", systemImage: "paperplane.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.purple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
    }
}
