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

                // 2. 端到端加密设置
                securitySection

                // 3. 隐私与数据安全
                privacySection

                // 4. 实时调试日志
                debugLogSection

                // 5. 关于与版本
                aboutSection
            }
            .navigationTitle("设置")
            .sheet(isPresented: $isPairingSheetPresented) {
                PairingSheet(isPresented: $isPairingSheetPresented)
            }
            .alert("确定解除与当前电脑的信任绑定？", isPresented: $showResetAlert) {
                Button("解除绑定", role: .destructive) {
                    bluetooth.disconnect()
                    store.savePairingPIN("")
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 1. 已配对设备

    private var pairedDevicesSection: some View {
        Section("已配对的 Windows 电脑") {
            HStack {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bluetooth.connectedDeviceName ?? "Windows PC")
                        .font(.headline)
                    Text(bluetooth.connectionState == .connected ? "🟢 已加密连接" : "⚪ 离线 · 等待重连")
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

    // MARK: - 2. 安全加密

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

    // MARK: - 3. 隐私与数据

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
