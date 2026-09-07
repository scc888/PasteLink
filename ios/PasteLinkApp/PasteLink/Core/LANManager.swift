import Foundation
import Network
import os
import UIKit

private let logger = Logger(subsystem: "com.pastelink.app", category: "LANManager")

/// 局域网高速直连管理器
///
/// 负责局域网发现与探测 (BLE 握手透传 IP / UDP 广播 / 本地 IP 探活),
/// 以及基于零信任 AES-256-GCM 密文通道的高速 HTTP 传输。
///
/// @author PasteLink
/// @date 2026-09-07
final class LANManager: ObservableObject {
    static let shared = LANManager()

    /// 局域网服务端口定义 (与 Windows 端对齐)
    static let defaultTcpPort: Int = 52089
    static let defaultUdpPort: UInt16 = 52088

    // MARK: - Published 状态

    /// 局域网高速通道是否可用
    @Published var isLanAvailable: Bool = false

    /// 电脑端局域网直连完整 Endpoint (如 "http://192.168.1.100:52089")
    @Published var lanEndpoint: String? = nil

    /// 局域网往返探测延迟 (毫秒)
    @Published var lastPingLatencyMs: Int = 0

    /// 局域网发现的电脑名称
    @Published var lanDeviceName: String = "Windows 电脑"

    /// 最后一次探测时间
    @Published var lastCheckedTime: Date? = nil

    // MARK: - 私有属性

    private var heartbeatTimer: Timer?
    private let urlSession: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.urlSession = URLSession(configuration: config)

        // 恢复上一次记忆的有效局域网地址
        if let saved = UserDefaults.standard.string(forKey: "lastKnownLanEndpoint"), !saved.isEmpty {
            self.lanEndpoint = saved
        }

        // 启动后台定期探活与网络切换检测
        startMonitoring()
    }

    deinit {
        heartbeatTimer?.invalidate()
    }

    // MARK: - 端点配置与主动探测

    /// 配置从 BLE 握手或 UDP 广播中获取到的 Windows 局域网端点
    func setDiscoveredEndpoint(ip: String, port: Int = defaultTcpPort) {
        let cleanIp = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIp.isEmpty else { return }

        let endpoint = "http://\(cleanIp):\(port)"
        if self.lanEndpoint != endpoint {
            self.lanEndpoint = endpoint
            logger.info("📍 更新电脑局域网端点: \(endpoint)")
        }

        // 立即发起异步探活校验
        Task {
            await ping(endpoint: endpoint)
        }
    }

    /// 探活指定端点 (GET /api/ping)
    @discardableResult
    func ping(endpoint: String? = nil) async -> Bool {
        guard let ep = endpoint ?? self.lanEndpoint,
              let url = URL(string: "\(ep)/api/ping") else {
            await MainActor.run { self.isLanAvailable = false }
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.2 // 超轻量快速探活

        let startTime = Date()
        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["status"] as? String == "ok" {
                let latency = max(1, Int(Date().timeIntervalSince(startTime) * 1000))
                let devName = json["device_name"] as? String ?? "Windows 电脑"

                await MainActor.run {
                    self.isLanAvailable = true
                    self.lanEndpoint = ep
                    self.lanDeviceName = devName
                    self.lastPingLatencyMs = latency
                    self.lastCheckedTime = Date()
                    UserDefaults.standard.set(ep, forKey: "lastKnownLanEndpoint")
                }
                return true
            }
        } catch {
            // 探活失败或超时 (如电脑睡眠、断开 Wi-Fi 或跨网段)
        }

        await MainActor.run {
            if self.lanEndpoint == ep {
                self.isLanAvailable = false
            }
        }
        return false
    }

    /// 发起 UDP 局域网广播自动发现 (针对电脑无蓝牙或离线场景)
    func discoverViaUDP() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let sock = socket(AF_INET, SOCK_DGRAM, 0)
            guard sock >= 0 else { return }
            defer { close(sock) }

            var broadcastEnable: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))

            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(Self.defaultUdpPort).bigEndian
            addr.sin_addr.s_addr = INADDR_BROADCAST

            let msg = "PASTELINK_DISCOVER"
            _ = msg.withCString { cstr in
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(sock, cstr, strlen(cstr), 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            var buf = [UInt8](repeating: 0, count: 1024)
            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, &buf, buf.count, 0, sa, &senderLen)
                }
            }

            if bytesRead > 0 {
                let resp = String(decoding: buf[0..<bytesRead], as: UTF8.self)
                if resp.hasPrefix("PASTELINK_OFFER:") {
                    let jsonStr = resp.dropFirst("PASTELINK_OFFER:".count)
                    if let data = jsonStr.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let ip = dict["ip"] as? String,
                       let port = dict["port"] as? Int {
                        DispatchQueue.main.async {
                            self.setDiscoveredEndpoint(ip: ip, port: port)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 极速数据收发接口 (端到端加密)

    /// 向 Windows 电脑高速推送密文载荷 (POST /api/clipboard)
    func sendPayloadOverLAN(encryptedData: Data) async -> Bool {
        guard isLanAvailable, let ep = lanEndpoint,
              let url = URL(string: "\(ep)/api/clipboard") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = encryptedData
        request.timeoutInterval = 4.0

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        } catch {
            logger.error("⚡ [LAN] 推送失败: \(error.localizedDescription)")
        }
        return false
    }

    /// 从 Windows 电脑高速秒级拉取最新剪贴板密文载荷 (GET /api/clipboard/latest)
    func fetchLatestOverLAN() async -> Data? {
        guard isLanAvailable, let ep = lanEndpoint,
              let url = URL(string: "\(ep)/api/clipboard/latest") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5

        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                return data
            }
        } catch {
            logger.error("⚡ [LAN] 拉取最新剪贴板失败: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - 定时心跳与网络状态保活

    private func startMonitoring() {
        // 每 8 秒探活一次当前局域网连接
        DispatchQueue.main.async {
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.lanEndpoint != nil {
                    Task {
                        await self.ping()
                    }
                } else {
                    self.discoverViaUDP()
                }
            }
        }

        // 监听进入前台通知，立即探活与重新发现
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.lanEndpoint != nil {
                Task {
                    await self.ping()
                }
            }
            self.discoverViaUDP()
        }
    }
}
