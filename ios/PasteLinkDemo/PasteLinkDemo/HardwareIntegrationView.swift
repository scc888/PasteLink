import SwiftUI

/// Tab 2: 快捷入口与系统硬件联动设置专区
struct HardwareIntegrationView: View {
    @ObservedObject private var liveActivityManager = LiveActivityManager.shared

    /// 预置的 iCloud 快捷指令链接 (根据分享的专属 ID)
    private static let defaultCopyShortcutURL = "https://www.icloud.com/shortcuts/d5f9ee8833d1438da18fab68ee3369be"
    private static let defaultPushShortcutURL = "https://www.icloud.com/shortcuts/6a153344cff7464f9e7bf0df3c84ca9e"

    @AppStorage("copyShortcutURL") private var copyShortcutURL: String = defaultCopyShortcutURL
    @AppStorage("pushShortcutURL") private var pushShortcutURL: String = defaultPushShortcutURL
    @State private var isCustomLinksExpanded: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // 1. Action Button (操作按钮) 核心推荐
                actionButtonSection

                // 2. 灵动岛 & 锁屏实时活动设置
                dynamicIslandSection

                // 3. iOS 18 控制中心小组件
                controlCenterSection

                // 4. Apple 快捷指令一键安装与测试
                shortcutsInstallSection

                // 5. 轻点背面 (Back Tap) 辅助手势
                backTapSection
            }
            .navigationTitle("快捷形态")
        }
    }

    // MARK: - 1. Action Button 操作按钮专属卡片

    private var actionButtonSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "button.programmable")
                        .font(.title2)
                        .foregroundStyle(.purple)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Action Button (操作按钮)")
                            .font(.headline)
                        Text("iPhone 15/16/17 Pro 专属 · 侧边物理键瞬间同步")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // 交互步骤示意
                VStack(alignment: .leading, spacing: 8) {
                    stepRow(number: "1", title: "打开系统「设置」→「操作按钮」")
                    stepRow(number: "2", title: "左右滑动选择「快捷指令」")
                    stepRow(number: "3", title: "指定为「PasteLink 一键复制」或「一键推送」")
                }
                .padding(12)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    if let url = URL(string: "App-prefs:root=ACTION_BUTTON") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("前往系统设置操作按钮", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        } header: {
            Text("核心硬件联动 (最推荐)")
        }
    }

    // MARK: - 2. 灵动岛 & 实时活动

    private var dynamicIslandSection: some View {
        Section {
            Toggle(isOn: $liveActivityManager.isDynamicIslandEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("灵动岛 & 锁屏实时活动")
                            .font(.subheadline)
                        Text("仅在与电脑建立连接时常驻显示，断开连接自动退出")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "capsule.portrait.fill")
                        .foregroundStyle(.blue)
                }
            }

            Toggle(isOn: $liveActivityManager.isHapticFeedbackEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("触感震动反馈")
                            .font(.subheadline)
                        Text("写入系统剪贴板时产生轻微马达反馈")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                }
            }

            if liveActivityManager.isDynamicIslandEnabled {
                Button {
                    liveActivityManager.showLiveActivity(text: "https://pastelink.app · 测试预览", deviceName: "Windows PC", force: true)
                } label: {
                    Label("立即测试弹出灵动岛", systemImage: "sparkles")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("灵动岛通知形态")
        }
    }

    // MARK: - 3. 控制中心小组件

    private var controlCenterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("从屏幕右上角下拉「控制中心」→ 点击左上角 [+] → 搜索「PasteLink」即可添加「一键复制」与「一键推送」专属圆形快捷按钮。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.vertical, 4)
        } header: {
            Text("iOS 18 控制中心小组件")
        }
    }

    // MARK: - 4. 快捷指令一键直达安装与自动化

    private var shortcutsInstallSection: some View {
        Section {
            // 1. 一键复制快捷指令
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("PasteLink 一键复制")
                            .font(.headline)
                        Text("Windows → iPhone · 从电脑获取最新内容并写入剪贴板")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        installShortcut(urlStr: copyShortcutURL)
                    } label: {
                        Label("一键直达添加", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        runShortcut(name: "PasteLink 一键复制")
                    } label: {
                        Label("测试运行", systemImage: "play.fill")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)

            // 2. 一键推送快捷指令
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                        .foregroundStyle(.purple)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("PasteLink 一键推送")
                            .font(.headline)
                        Text("iPhone → Windows · 将手机剪贴板秒级推送到电脑")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        installShortcut(urlStr: pushShortcutURL)
                    } label: {
                        Label("一键直达添加", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.purple)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        runShortcut(name: "PasteLink 一键推送")
                    } label: {
                        Label("测试运行", systemImage: "play.fill")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)

            // 3. 自定义 / 查看 iCloud 分享链接 (折叠配置)
            DisclosureGroup(isExpanded: $isCustomLinksExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("一键复制 iCloud 链接:")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        TextField("iCloud 快捷指令链接", text: $copyShortcutURL)
                            .font(.caption)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("一键推送 iCloud 链接:")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        TextField("iCloud 快捷指令链接", text: $pushShortcutURL)
                            .font(.caption)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }

                    Button("恢复为默认官方分享链接") {
                        copyShortcutURL = Self.defaultCopyShortcutURL
                        pushShortcutURL = Self.defaultPushShortcutURL
                    }
                    .font(.caption2)
                    .foregroundStyle(.blue)
                }
                .padding(.top, 6)
            } label: {
                Label("自定义或查看 iCloud 快捷指令 ID", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 4. 原生 AppIntents 系统动作介绍
            VStack(alignment: .leading, spacing: 6) {
                Text("高级编排：PasteLink 原生系统动作已深度集成")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                HStack {
                    Label("获取 Windows 最新剪贴板", systemImage: "doc.on.clipboard.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.blue)
                    Spacer()
                    Text("系统动作 · 免打开 App")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Label("发送到 Windows 剪贴板", systemImage: "paperplane.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.purple)
                    Spacer()
                    Text("系统动作 · 蓝牙直发")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    if let url = URL(string: "shortcuts://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开 Apple「快捷指令」App 手动编排", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.top, 4)
        } header: {
            Text("Apple 快捷指令一键直达安装")
        } footer: {
            Text("点击「一键直达添加」将直接弹出系统原生快捷指令安装面板。安装完成后，可放置于桌面「快捷指令小组件」、绑定「轻点背面」或「Action Button」。")
                .font(.caption2)
        }
    }

    // MARK: - 5. 轻点背面

    private var backTapSection: some View {
        Section("辅助手势") {
            VStack(alignment: .leading, spacing: 6) {
                Text("系统「设置」→「辅助功能」→「触控」→「轻点背面」→ 双击或三击选择「PasteLink 一键复制」，敲击手机背壳两下即可同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.vertical, 2)
        }
    }

    private func stepRow(number: String, title: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.caption2.bold())
                .frame(width: 18, height: 18)
                .background(Color.purple.opacity(0.2), in: Circle())
                .foregroundStyle(.purple)
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    private func installShortcut(urlStr: String) {
        let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let url = URL(string: trimmed) {
            UIApplication.shared.open(url)
        }
    }

    private func runShortcut(name: String) {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        if let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
}
