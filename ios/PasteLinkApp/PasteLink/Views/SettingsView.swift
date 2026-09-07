import SwiftUI

/// Tab 3: 设备管理与安全设置中心
struct SettingsView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var store = PasteLinkStore.shared

    @State private var isPairingSheetPresented: Bool = false
    @State private var isLogExpanded: Bool = false
    @State private var showResetAlert: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // 1. 已信任电脑设备
                pairedDevicesSection

                // 2. 外观与显示模式 (深色模式)
                appearanceSection

                // 3. 端到端加密设置
                securitySection

                // 4. 剪贴板历史记录设置
                historySection

                // 4. 隐私与数据安全
                privacySection

                // 5. 实时调试日志
                debugLogSection

                // 6. 关于与版本
                aboutSection
            }
            .navigationTitle("设置")
            .sheet(isPresented: $isPairingSheetPresented) {
                PairingSheet(isPresented: $isPairingSheetPresented)
            }
            .alert("确定解除与当前电脑的信任绑定？", isPresented: $showResetAlert) {
                Button("解除绑定", role: .destructive) {
                    bluetooth.disconnect()
                    bluetooth.connectedDeviceName = nil
                    bluetooth.isAuthFailed = false
                    store.savePairingPIN("")
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 1. 已配对设备

    private var pairedDevicesSection: some View {
        Section("已配对的 Windows 电脑") {
            if store.pairedPIN.isEmpty && bluetooth.connectionState != .connected {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("暂无信任设备")
                            .font(.subheadline.bold())
                        Text("请在主页点击「配对码」绑定电脑")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("去配对") {
                        isPairingSheetPresented = true
                    }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .font(.title2)
                        .foregroundStyle(bluetooth.connectionState == .connected ? .blue : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(bluetooth.connectedDeviceName ?? "Windows PC")
                            .font(.headline)
                        Text(bluetooth.connectionState == .connected ? (bluetooth.isAuthFailed ? "🔴 配对码错误" : "🟢 已加密连接") : "⚪ 离线 · 等待重连")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("解除绑定", role: .destructive) {
                        showResetAlert = true
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 2. 外观与显示模式 (深色模式)

    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("深色模式", systemImage: store.appTheme.iconName)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(store.appTheme.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Picker("外观模式", selection: Binding(
                    get: { store.appTheme },
                    set: { store.setAppTheme($0) }
                )) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.title, systemImage: theme.iconName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)
        } header: {
            Text("外观与显示")
        } footer: {
            Text("选择「跟随系统」将随 iOS 系统自动切换；选择「浅色模式」或「深色模式」将在应用内锁定对应外观。")
        }
    }

    // MARK: - 3. 安全加密

    private var securitySection: some View {
        Section("安全与配对") {
            HStack {
                Label("6 位安全配对码", systemImage: "key.fill")
                    .foregroundStyle(.primary)

                Spacer()

                Text(formattedPIN)
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundStyle(.blue)

                Button("修改") {
                    isPairingSheetPresented = true
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AES-256-GCM 认证加密")
                        .font(.subheadline)
                    Text("蓝牙空口数据全量加密，杜绝嗅探窃听")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - 3. 历史记录设置

    private var historySection: some View {
        Section {
            Picker("历史记录上限", selection: Binding(
                get: { store.maxHistoryCount },
                set: { store.setMaxHistoryCount($0) }
            )) {
                Text("5 条").tag(5)
                Text("10 条 (默认)").tag(10)
                Text("20 条").tag(20)
                Text("30 条").tag(30)
                Text("50 条").tag(50)
            }

            Button(role: .destructive) {
                store.clearHistory()
            } label: {
                HStack {
                    Label("清空所有历史记录", systemImage: "trash")
                        .foregroundStyle(.red)
                    Spacer()
                    Text("\(store.history.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("剪贴板历史")
        } footer: {
            Text("超出设定上限时将自动淘汰最旧的未收藏记录。已置顶/收藏（📌）的条目不受上限限制，始终保留。")
        }
    }

    // MARK: - 4. 隐私与数据

    private var privacySection: some View {
        Section("隐私保护 (Local-First)") {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("零云端存储承诺")
                        .font(.subheadline)
                    Text("所有数据仅在本地蓝牙硬件直连链路传输，无任何中心化服务器")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.circle.fill")
                    .foregroundStyle(.purple)
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("密码管理器敏感避让")
                        .font(.subheadline)
                    Text("Windows 端自动阻断 1Password/Bitwarden 密码同步")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 4. 调试日志

    private var debugLogSection: some View {
        Section {
            DisclosureGroup("底层运行日志 (\(bluetooth.debugLogs.count))", isExpanded: $isLogExpanded) {
                if bluetooth.debugLogs.isEmpty {
                    Text("暂无日志")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(bluetooth.debugLogs.enumerated()), id: \.offset) { _, log in
                                Text(log)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        } header: {
            Text("开发与诊断")
        }
    }

    // MARK: - 5. 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("客户端版本")
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") (Production)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("通信协议")
                Spacer()
                Text("BLE GATT 64KB UTF-8")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于 PasteLink")
        }
    }

    private var formattedPIN: String {
        let pin = store.pairedPIN
        if pin.count == 6 {
            let start = pin.prefix(3)
            let end = pin.suffix(3)
            return "\(start) \(end)"
        }
        return pin.isEmpty ? "未配置" : pin
    }
}

#Preview {
    SettingsView(bluetooth: BluetoothManager.shared)
}
