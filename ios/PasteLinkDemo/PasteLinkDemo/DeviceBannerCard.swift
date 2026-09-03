import SwiftUI

/// 顶部设备状态英雄卡片
struct DeviceBannerCard: View {
    @ObservedObject var bluetooth: BluetoothManager
    var onOpenPairing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 第一行：设备类型与连接徽标
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.title3)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(bluetooth.connectedDeviceName ?? (bluetooth.connectionState == .connected ? "Windows 电脑" : "等待连接 Windows"))
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

            // 第二行：特性指示标签 (低功耗蓝牙 / 端到端加密 / 无感同步)
            HStack(spacing: 12) {
                featureBadge(icon: "bolt.shield.fill", text: "AES-256-GCM 加密", color: .green)
                featureBadge(icon: "wave.3.forward", text: "BLE 低延迟", color: .blue)
                Spacer()

                // 快捷操作按钮
                if bluetooth.connectionState == .scanning {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if bluetooth.connectionState != .connected {
                    Button("扫描连接") {
                        bluetooth.startScanning()
                    }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .clipShape(Capsule())
                } else {
                    Button("断开") {
                        bluetooth.disconnect()
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
                        .stroke(bluetooth.connectionState == .connected ? Color.blue.opacity(0.25) : Color.clear, lineWidth: 1.5)
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

    private var statusColor: Color {
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
        switch bluetooth.connectionState {
        case .connected:
            if bluetooth.isAuthFailed {
                return "❌ 配对码不匹配 · 数据解密失败"
            } else if PasteLinkStore.shared.pairedPIN.isEmpty {
                return "蓝牙已连接 · 需配置安全码以解密"
            } else {
                return "已加密连接 · 实时待命"
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
