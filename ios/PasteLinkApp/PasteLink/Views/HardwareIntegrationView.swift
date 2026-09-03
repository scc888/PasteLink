import SwiftUI

/// Tab 2: 快捷入口与系统硬件联动设置专区
struct HardwareIntegrationView: View {
    @ObservedObject private var liveActivityManager = LiveActivityManager.shared

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
                    if let url = URL(string: UIApplication.openSettingsURLString) {
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
                        Text("Windows 复制时自动在灵动岛展示预览，点击一键粘贴")
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
                    liveActivityManager.showLiveActivity(text: "https://pastelink.app · 测试预览", deviceName: "Windows PC")
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

    // MARK: - 4. 快捷指令与系统自动化

    private var shortcutsInstallSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("PasteLink 动作已通过 AppIntents 深度内置于 iOS 系统中，无需下载任何第三方脚本：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("获取 Windows 最新剪贴板", systemImage: "doc.on.clipboard.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                        Text("系统原生动作 · 读取电脑最新同步文本")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("发送到 Windows 剪贴板", systemImage: "paperplane.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.purple)
                        Text("系统原生动作 · 将手机内容蓝牙直发电脑")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Button {
                    if let url = URL(string: "shortcuts://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开 Apple「快捷指令」App", systemImage: "plus.circle.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Apple 快捷指令原生集成")
        } footer: {
            Text("在「快捷指令」中点击 [+] 新建，搜索「PasteLink」即可自由编排自动化流程。")
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
        if !urlStr.isEmpty, let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    HardwareIntegrationView()
}
