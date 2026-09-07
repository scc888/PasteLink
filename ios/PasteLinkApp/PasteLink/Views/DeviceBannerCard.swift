import SwiftUI

/// 顶部设备状态英雄卡片
struct DeviceBannerCard: View {
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var lan: LANManager = LANManager.shared
    var onOpenPairing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 第一行：设备类型与连接徽标
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.title3)
                        .foregroundStyle(lan.isLanAvailable ? .orange : .blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(deviceNameText)
                            .font(.headline)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                                .shadow(color: statusColor.opacity(0.6), radius: 4)

                            Text(statusDescription)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                // 配对码设置按钮
                Button {
                    onOpenPairing()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption2)
                        Text("配对码")
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                }
            }

            // 第二行：特性指示标签 (双模极速 / 低功耗蓝牙 / 端到端加密)
            HStack(spacing: 8) {
                featureBadge(icon: "bolt.shield.fill", text: "AES-256 加密", color: .green)
                if lan.isLanAvailable {
                    featureBadge(icon: "bolt.horizontal.fill", text: "局域网极速 (\(lan.lastPingLatencyMs)ms)", color: .orange)
                } else {
                    featureBadge(icon: "wave.3.forward", text: "BLE 低延迟", color: .blue)
                }
                Spacer()

                // 快捷操作按钮
                if bluetooth.connectionState == .scanning {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if bluetooth.connectionState != .connected && !lan.isLanAvailable {
                    Button("扫描连接") {
                        bluetooth.startScanning()
                    }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .clipShape(Capsule())
                } else {
                    Button(bluetooth.connectionState == .connected ? "断开" : "刷新") {
                        if bluetooth.connectionState == .connected {
                            bluetooth.disconnect()
                        } else {
                            Task { await lan.ping() }
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(lan.isLanAvailable ? Color.orange.opacity(0.3) : (bluetooth.connectionState == .connected ? Color.blue.opacity(0.25) : Color.clear), lineWidth: 1.5)
                )
        )
    }

    private func featureBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var deviceNameText: String {
        if let name = bluetooth.connectedDeviceName {
            return name
        }
        if lan.isLanAvailable {
            return lan.lanDeviceName
        }
        return bluetooth.connectionState == .connected ? "Windows 电脑" : "等待连接 Windows"
    }

    private var statusColor: Color {
        if lan.isLanAvailable {
            return .green
        }
        switch bluetooth.connectionState {
        case .connected:
            if bluetooth.isAuthFailed {
                return .red
            }
            return PasteLinkStore.shared.pairedPIN.isEmpty ? .orange : .green
        case .scanning, .connecting:
            return .orange
        case .disconnected:
            return .red
        }
    }

    private var statusDescription: String {
        if lan.isLanAvailable {
            return "⚡ 局域网极速直连就绪 (无损图片秒传)"
        }
        switch bluetooth.connectionState {
        case .connected:
            if bluetooth.isAuthFailed {
                return "❌ 配对码不匹配 · 数据解密失败"
            } else if PasteLinkStore.shared.pairedPIN.isEmpty {
                return "蓝牙已连接 · 需配置安全码以解密"
            } else {
                return "📶 蓝牙低功耗已连接 · 实时待命"
            }
        case .scanning:
            return "正在搜寻周围设备..."
        case .connecting:
            return "正在建立通信握手..."
        case .disconnected:
            return "未连接 (请确保电脑端 PasteLink 运行)"
        }
    }
}

#Preview {
    DeviceBannerCard(bluetooth: BluetoothManager.shared) {}
        .padding()
}
