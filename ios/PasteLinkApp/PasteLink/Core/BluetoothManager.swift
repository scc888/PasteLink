import ActivityKit
import CoreBluetooth
import Foundation
import os
import UIKit
import WidgetKit

/// 发现的 BLE 设备模型
struct DiscoveredDevice: Identifiable {
    var id: UUID { peripheral.identifier }
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    let isPasteLinkCandidate: Bool
}

/// 实时分片传输状态模型 (供 UI 渲染进度条与动效)
struct TransferState: Equatable {
    enum Direction: Equatable {
        case sending
        case receiving

        var title: String {
            switch self {
            case .sending: return "正在向 Windows 推送无损图片"
            case .receiving: return "正在接收来自 Windows 的图片"
            }
        }

        var iconName: String {
            switch self {
            case .sending: return "arrow.up.circle.fill"
            case .receiving: return "arrow.down.circle.fill"
            }
        }
    }

    var direction: Direction
    var currentChunk: Int
    var totalChunks: Int
    var progressPercentage: Int // 0..100
    var detailText: String
    var targetSha256: String? = nil
}

/// BLE Central 管理器
///
/// 负责扫描、连接 Windows 端的 PasteLink GATT Server,
/// 订阅剪贴板 Notify, 以及向 Windows 发送剪贴板内容。
///
/// @author PasteLink
/// @date 2026-09-01
final class BluetoothManager: NSObject, ObservableObject {

    /// 单例访问点 (供 App 与 App Intents / Shortcuts 共享状态)
    static let shared = BluetoothManager()

    // MARK: - UUIDs (必须与 Windows 端一致)

    /// PasteLink 服务 UUID
    static let serviceUUID = CBUUID(string: "D7E5A001-7C8B-4F9E-B8A3-2C1D4E5F6A7B")

    /// Windows → iPhone (Read + Notify)
    static let clipboardNotifyUUID = CBUUID(string: "D7E5A002-7C8B-4F9E-B8A3-2C1D4E5F6A7B")

    /// iPhone → Windows (Write)
    static let clipboardWriteUUID = CBUUID(string: "D7E5A003-7C8B-4F9E-B8A3-2C1D4E5F6A7B")

    // MARK: - 连接状态

    enum ConnectionState {
        case disconnected
        case scanning
        case connecting
        case connected
    }

    // MARK: - Published 属性

    /// 当前连接状态 (变更时联动灵动岛生命周期：已连接常驻，非连接退出)
    @Published var connectionState: ConnectionState = .disconnected {
        didSet {
            guard oldValue != connectionState else { return }
            handleConnectionStateChange(from: oldValue, to: connectionState)
        }
    }

    /// 实时传输状态 (用于驱动前台进度条浮窗)
    @Published var currentTransfer: TransferState? = nil

    /// 状态文本
    @Published var statusText: String = "未连接"

    /// 配对码解密认证是否失败 (提示用户核对 6 位 PIN 码)
    @Published var isAuthFailed: Bool = false {
        didSet {
            if isAuthFailed {
                LiveActivityManager.shared.endCurrentActivity()
            } else if connectionState == .connected {
                LiveActivityManager.shared.startActivityIfConnected(deviceName: connectedDeviceName ?? "Windows 电脑")
            }
        }
    }

    /// 是否触发自动弹出配对码输入弹窗 (新设备连接或未配置配对码时)
    @Published var shouldShowPairingPrompt: Bool = false

    /// 已连接的设备名称
    @Published var connectedDeviceName: String?

    /// 扫描到的设备列表 (供手动选择连接)
    @Published var discoveredDevices: [DiscoveredDevice] = []

    /// 最后收到的文本
    @Published var lastReceivedText: String?

    /// 最后收到的时间
    @Published var lastReceivedTime: Date?

    /// 最近调试日志
    @Published var debugLogs: [String] = []

    // MARK: - 私有属性

    /// CoreBluetooth 中心管理器
    private var centralManager: CBCentralManager!

    /// 已连接的 Peripheral
    private var connectedPeripheral: CBPeripheral?

    /// 写入 Characteristic 引用
    private var writeCharacteristic: CBCharacteristic?

    /// 通知订阅与连接尝试的状态，用于避免过期回调影响新连接。
    private var notifyCharacteristic: CBCharacteristic?
    private var connectionAttemptID = UUID()
    private var scanAttemptID = UUID()

    /// 日志
    private let logger = Logger(subsystem: "com.pastelink.app", category: "Bluetooth")

    /// 用户是否主动手动断开 (主动断开时不触发自动后台重连)
    private var isManualDisconnect: Bool = false

    /// 配对握手校验异步挂起回调
    private var pendingAuthContinuation: CheckedContinuation<(success: Bool, message: String), Never>?
    private var pendingAuthPIN: String?
    private var pendingChallengeID: String?

    /// BLE 分片切片与重组协议
    private let chunkReassembler = BLEChunkReassembler()
    private var rollingMsgId: UInt8 = 1

    /// 最近处理过的剪贴板 SHA-256 哈希 (用于局域网与 BLE 并发到达时的幂等去重)
    private var lastProcessedSha256: String?

    /// BLE 写入事务流控信号量 (严格对齐 Apple CoreBluetooth .withResponse 回调规范，防高并发丢包)
    private let writeSemaphore = DispatchSemaphore(value: 0)

    // MARK: - 初始化

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            // 启用 State Restoration, 让 iOS 在 App 被杀死后恢复 BLE 连接
            CBCentralManagerOptionRestoreIdentifierKey: "com.pastelink.central"
        ])
        setupDarwinNotificationObserver()
    }

    /// 监听来自 App Extensions / 快捷指令 / 小组件的发送请求
    private func setupDarwinNotificationObserver() {
        let callback: CFNotificationCallback = { _, _, name, _, _ in
            guard let name = name?.rawValue as String?, name == "com.pastelink.sendPendingClipboard" else { return }
            let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
            let sendType = defaults.string(forKey: "pendingSendType") ?? "text"

            if sendType == "image",
               let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") {
                let pendingImgURL = containerURL.appendingPathComponent("pending_send_image.png")
                if let data = try? Data(contentsOf: pendingImgURL), let img = UIImage(data: data) {
                    DispatchQueue.main.async {
                        if BluetoothManager.shared.connectionState == .connected {
                            try? FileManager.default.removeItem(at: pendingImgURL)
                            defaults.removeObject(forKey: "pendingSendType")
                            BluetoothManager.shared.sendImageToWindows(image: img)
                        } else {
                            BluetoothManager.shared.addLog("📡 收到图片推送请求，正在自动重连 Windows 电脑...")
                            BluetoothManager.shared.startScanning()
                        }
                    }
                }
            } else if let pending = defaults.string(forKey: "pendingSendToWindows"), !pending.isEmpty {
                DispatchQueue.main.async {
                    if BluetoothManager.shared.connectionState == .connected {
                        defaults.removeObject(forKey: "pendingSendType")
                        defaults.removeObject(forKey: "pendingSendToWindows")
                        BluetoothManager.shared.sendToWindows(text: pending)
                    } else {
                        BluetoothManager.shared.addLog("📡 收到文本推送请求，正在自动重连 Windows 电脑...")
                        BluetoothManager.shared.startScanning()
                    }
                }
            }
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            "com.pastelink.sendPendingClipboard" as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - 公开方法

    /// 开始扫描 PasteLink 设备 (同时支持广播过滤与通配扫描)
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            statusText = "蓝牙未开启"
            addLog("⚠️ 尝试扫描但蓝牙未开启 (状态: \(centralManager.state.rawValue))")
            return
        }

        guard connectedPeripheral == nil, connectionState != .connecting, connectionState != .connected else {
            addLog("ℹ️ 已在连接或已连接，跳过重复扫描")
            return
        }
        guard !(connectionState == .scanning && centralManager.isScanning) else { return }
        isManualDisconnect = false
        let scanID = UUID()
        scanAttemptID = scanID

        connectionState = .scanning
        statusText = "正在扫描附近的 PasteLink 电脑..."
        discoveredDevices.removeAll()
        addLog("🔍 开始扫描 PasteLink 电脑...")

        // 前台保留兼容扫描；后台必须指定服务 UUID 才能扫描。
        centralManager.scanForPeripherals(
            withServices: UIApplication.shared.applicationState == .active ? nil : [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // 30 秒超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.scanAttemptID == scanID, self.connectionState == .scanning else { return }
            self.centralManager.stopScan()
            self.connectionState = .disconnected
            if self.discoveredDevices.isEmpty {
                self.statusText = "未找到 PasteLink 电脑 (请确保电脑端运行)"
                self.addLog("⏱️ 扫描超时，未发现本程序电脑")
            } else {
                self.statusText = "扫描完成，请在下方选择电脑连接"
            }
            self.scheduleReconnect(after: 5)
        }
    }

    /// 手动连接指定设备
    func connect(to peripheral: CBPeripheral) {
        guard centralManager.state == .poweredOn else {
            addLog("⚠️ 蓝牙未就绪，无法发起连接")
            return
        }
        guard connectedPeripheral == nil, connectionState != .connecting, connectionState != .connected else {
            addLog("ℹ️ 已有连接或连接请求，忽略重复连接")
            return
        }
        isManualDisconnect = false
        centralManager.stopScan()
        scanAttemptID = UUID()
        connectedPeripheral = peripheral
        writeCharacteristic = nil
        notifyCharacteristic = nil
        peripheral.delegate = self
        connectionState = .connecting
        let attemptID = UUID()
        connectionAttemptID = attemptID
        let name = peripheral.name ?? "设备"
        statusText = "正在连接 \(name)..."
        addLog("🔗 发起蓝牙连接")

        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
        scheduleConnectionTimeout(for: peripheral, attemptID: attemptID)
    }

    private func scheduleConnectionTimeout(for peripheral: CBPeripheral, attemptID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.connectionAttemptID == attemptID,
                  self.connectionState == .connecting,
                  self.connectedPeripheral?.identifier == peripheral.identifier else { return }
            self.addLog("⚠️ 蓝牙连接或订阅超时，准备重新扫描")
            self.statusText = "连接超时，正在重试"
            // 等待 CoreBluetooth 的断开/连接失败回调清理本次连接，
            // 避免旧连接的迟到回调误清理同一设备的新连接。
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isManualDisconnect, self.connectedPeripheral == nil,
                  self.connectionState == .disconnected,
                  self.centralManager.state == .poweredOn else { return }
            self.startScanning()
        }
    }

    /// 重新进入前台时恢复自动发现，不覆盖已有连接或用户主动断开。
    func resumeConnectionIfNeeded() {
        guard !isManualDisconnect, centralManager.state == .poweredOn,
              connectedPeripheral == nil,
              connectionState != .connecting, connectionState != .connected else { return }
        if centralManager.isScanning {
            centralManager.stopScan()
        }
        connectionState = .disconnected
        startScanning()
    }

    /// 已在扫描时切换为后台可用的服务过滤条件。
    func prepareBackgroundScanIfNeeded() {
        guard connectionState == .scanning, centralManager.state == .poweredOn,
              centralManager.isScanning else { return }
        centralManager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func isConnecting(to peripheral: CBPeripheral) -> Bool {
        connectionState == .connecting && connectedPeripheral?.identifier == peripheral.identifier
    }

    /// 断开连接
    func disconnect() {
        isManualDisconnect = true
        centralManager.stopScan()
        scanAttemptID = UUID()
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            connectionState = .disconnected
            statusText = "已手动断开"
        }
        currentTransfer = nil
    }

    /// 响应连接状态切换，实现灵动岛智能联动：真正连接时显示，非连接状态自动退出
    private func handleConnectionStateChange(from oldState: ConnectionState, to newState: ConnectionState) {
        switch newState {
        case .connected:
            let deviceName = connectedDeviceName ?? "Windows 电脑"
            addLog("🏝️ [BLE] 已真正连接，智能启动灵动岛")
            LiveActivityManager.shared.startActivityIfConnected(deviceName: deviceName)

        case .disconnected, .scanning, .connecting:
            addLog("🏝️ [BLE] 非连接状态 (\(newState))，自动退出灵动岛")
            LiveActivityManager.shared.endCurrentActivity()
        }
    }

    /// 向 Windows 发送文本 (支持局域网极速直连与 BLE 双模无缝回退)
    func sendToWindows(text: String) {
        let lanAvailable = LANManager.shared.isLanAvailable
        let bleAvailable = (connectedPeripheral != nil && writeCharacteristic != nil)

        guard lanAvailable || bleAvailable else {
            addLog("❌ 发送失败: 未连接或不可写")
            return
        }

        let pin = PasteLinkStore.shared.getPairingPIN()
        guard let encryptedData = try? CryptoEngine.encrypt(text: text, pin: pin) else {
            addLog("❌ 发送失败: AES-256-GCM 加密异常")
            return
        }

        guard encryptedData.count <= 10 * 1024 * 1024 else {
            addLog("❌ 发送失败: 文本过大 (\(encryptedData.count) 字节)")
            return
        }

        let item = PasteLinkStore.shared.saveSentItem(text: text)

        if lanAvailable {
            Task {
                let success = await LANManager.shared.sendPayloadOverLAN(encryptedData: encryptedData)
                if success {
                    self.addLog("⚡ [局域网极速推送] 文本已同步至 Windows [SHA: \(item.sha256.prefix(8))]")
                    return
                } else if bleAvailable {
                    self.addLog("⚠️ [局域网推送未达] 自动降级为蓝牙 BLE 发送...")
                    self.sendTextViaBLE(encryptedData: encryptedData, item: item)
                }
            }
            return
        }

        if bleAvailable {
            sendTextViaBLE(encryptedData: encryptedData, item: item)
        }
    }

    private func sendTextViaBLE(encryptedData: Data, item: ClipboardItem) {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { return }
        let msgId = rollingMsgId
        rollingMsgId = rollingMsgId &+ 1
        let chunks = BLEChunkProtocol.fragment(data: encryptedData, msgId: msgId)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for chunk in chunks {
                guard self.connectionState == .connected else { break }
                while self.writeSemaphore.wait(timeout: .now()) == .success {}
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                _ = self.writeSemaphore.wait(timeout: .now() + 0.6)
            }
            self.addLog("📤 [BLE 分片加密] 已发送 \(encryptedData.count) 字节 (\(chunks.count) 分片) [SHA: \(item.sha256.prefix(8))]")
        }
    }

    /// 向 Windows 发送无损 PNG 图片 (优先局域网极速直连秒级推送，无网络时无缝回退至 BLE)
    func sendImageToWindows(image: UIImage) {
        let lanAvailable = LANManager.shared.isLanAvailable
        let bleAvailable = (connectedPeripheral != nil && writeCharacteristic != nil)

        guard lanAvailable || bleAvailable else {
            addLog("❌ 发送图片失败: 未连接到电脑 (局域网与蓝牙均不可用)")
            return
        }

        guard let pngData = image.pngData() else {
            addLog("❌ 发送图片失败: 无法将图像转换为无损 PNG 格式")
            return
        }

        let width = UInt32(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let height = UInt32(image.cgImage?.height ?? Int(image.size.height * image.scale))

        let wrapped = CryptoEngine.wrapImagePayload(width: width, height: height, pngData: pngData)
        let pin = PasteLinkStore.shared.getPairingPIN()

        guard let encryptedData = try? CryptoEngine.encryptData(data: wrapped, pin: pin) else {
            addLog("❌ 发送图片失败: AES-256-GCM 加密异常")
            return
        }

        guard encryptedData.count <= 10 * 1024 * 1024 else {
            addLog("❌ 发送图片失败: 图片过大 (\(encryptedData.count) 字节)")
            return
        }

        let item = PasteLinkStore.shared.saveSentImage(pngData: pngData, width: Int(width), height: Int(height))

        // 1. 优先使用局域网极速通道直传 (通常 < 0.1s 传输完成)
        if lanAvailable {
            addLog("⚡ [局域网极速推送] 正在直连 Windows 推送图片 (\(width)×\(height), \(pngData.count) 字节)...")
            DispatchQueue.main.async {
                self.currentTransfer = TransferState(
                    direction: .sending,
                    currentChunk: 1,
                    totalChunks: 1,
                    progressPercentage: 50,
                    detailText: "⚡ 局域网极速直连推送中...",
                    targetSha256: item.sha256
                )
            }

            Task {
                let success = await LANManager.shared.sendPayloadOverLAN(encryptedData: encryptedData)
                if success {
                    await MainActor.run {
                        self.currentTransfer = TransferState(
                            direction: .sending,
                            currentChunk: 1,
                            totalChunks: 1,
                            progressPercentage: 100,
                            detailText: "⚡ 局域网直连推送完成 (100%)",
                            targetSha256: item.sha256
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if self.currentTransfer?.targetSha256 == item.sha256 {
                                self.currentTransfer = nil
                            }
                        }
                    }
                    self.addLog("✅ [局域网极速推送完成] 无损图片已秒级同步至 Windows 剪贴板 [SHA: \(item.sha256.prefix(8))]")
                    return
                } else {
                    self.addLog("⚠️ [局域网直连失败] 自动无缝降级为蓝牙 BLE 分片传输...")
                    if bleAvailable {
                        self.sendImageViaBLE(encryptedData: encryptedData, item: item, width: width, height: height, pngByteCount: pngData.count)
                    }
                }
            }
            return
        }

        // 2. 蓝牙回退通道
        if bleAvailable {
            sendImageViaBLE(encryptedData: encryptedData, item: item, width: width, height: height, pngByteCount: pngData.count)
        }
    }

    private func sendImageViaBLE(encryptedData: Data, item: ClipboardItem, width: UInt32, height: UInt32, pngByteCount: Int) {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { return }

        let msgId = rollingMsgId
        rollingMsgId = rollingMsgId &+ 1
        let chunks = BLEChunkProtocol.fragment(data: encryptedData, msgId: msgId)

        addLog("📤 [BLE 分片推送] 开始向 Windows 推送无损图片 (\(width)×\(height), \(pngByteCount) 字节, \(chunks.count) 分片)...")

        DispatchQueue.main.async {
            self.currentTransfer = TransferState(
                direction: .sending,
                currentChunk: 0,
                totalChunks: chunks.count,
                progressPercentage: 0,
                detailText: "准备推送 (0/\(chunks.count) 分片)",
                targetSha256: item.sha256
            )
        }

        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "PasteLinkSendImage") {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var writeFailed = false
            for (index, chunk) in chunks.enumerated() {
                guard self.connectionState == .connected else {
                    writeFailed = true
                    break
                }
                while self.writeSemaphore.wait(timeout: .now()) == .success {}
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                let waitResult = self.writeSemaphore.wait(timeout: .now() + 0.6)
                if waitResult == .timedOut {
                    self.logger.warning("⚠️ BLE 写入等待超时 (分片 \(index + 1)/\(chunks.count))")
                }

                let current = index + 1
                let pct = Int((Double(current) / Double(chunks.count)) * 100)

                if index % 3 == 0 || index == chunks.count - 1 {
                    DispatchQueue.main.async {
                        self.currentTransfer = TransferState(
                            direction: .sending,
                            currentChunk: current,
                            totalChunks: chunks.count,
                            progressPercentage: pct,
                            detailText: "\(current)/\(chunks.count) 分片 (\(pct)%)",
                            targetSha256: item.sha256
                        )
                    }
                }

                if index % 20 == 0 || index == chunks.count - 1 {
                    self.addLog("📤 [图片推送进度] \(pct)% (\(current)/\(chunks.count) 分片)")
                }
            }

            if writeFailed {
                self.addLog("❌ [BLE 图片推送失败] 蓝牙连接已中断")
                DispatchQueue.main.async {
                    self.currentTransfer = nil
                }
            } else {
                DispatchQueue.main.async {
                    self.currentTransfer = TransferState(
                        direction: .sending,
                        currentChunk: chunks.count,
                        totalChunks: chunks.count,
                        progressPercentage: 100,
                        detailText: "推送完成 (100%)",
                        targetSha256: item.sha256
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if self.currentTransfer?.targetSha256 == item.sha256 {
                        self.currentTransfer = nil
                    }
                }
                self.addLog("✅ [BLE 图片推送完成] 已将无损图片同步至 Windows 剪贴板 [SHA: \(item.sha256.prefix(8))]")
            }

            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
            }
        }
    }

    /// 直接发送文本 (供 App Intent / 快捷指令调用，支持局域网极速直发与蓝牙自动重连排队)
    @discardableResult
    func sendDirectly(text: String) async -> Bool {
        let pin = PasteLinkStore.shared.getPairingPIN()
        guard let encryptedData = try? CryptoEngine.encrypt(text: text, pin: pin),
              encryptedData.count <= 10 * 1024 * 1024
        else {
            return false
        }

        // 1. 优先局域网直发
        if LANManager.shared.isLanAvailable {
            let ok = await LANManager.shared.sendPayloadOverLAN(encryptedData: encryptedData)
            if ok {
                _ = PasteLinkStore.shared.saveSentItem(text: text)
                addLog("⚡ [快捷指令/局域网] 已极速推送到 Windows")
                return true
            }
        }

        // 2. 蓝牙连接检查
        guard connectionState == .connected,
              let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic
        else {
            let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
            defaults.set(text, forKey: "pendingSendToWindows")
            addLog("⚠️ 电脑暂未连接，已暂存待发文本")
            if centralManager.state == .poweredOn && connectionState == .disconnected {
                startScanning()
            }
            return false
        }

        let item = PasteLinkStore.shared.saveSentItem(text: text)
        let msgId = rollingMsgId
        rollingMsgId = rollingMsgId &+ 1
        let chunks = BLEChunkProtocol.fragment(data: encryptedData, msgId: msgId)

        for chunk in chunks {
            guard connectionState == .connected else { break }
            while writeSemaphore.wait(timeout: .now()) == .success {}
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            _ = writeSemaphore.wait(timeout: .now() + 0.6)
        }
        addLog("📤 [快捷指令/分片加密] 已推送到 Windows (\(chunks.count) 分片) [SHA: \(item.sha256.prefix(8))]")
        return true
    }

    /// 校验候选 PIN 码是否与当前 Windows 电脑匹配 (端到端加密握手挑战)
    func verifyPairingPIN(candidatePin: String) async -> (success: Bool, message: String) {
        guard connectionState == .connected,
              let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic
        else {
            return (false, "未连接到电脑，请确保电脑端运行中")
        }

        let cleanPin = candidatePin.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPin.count == 6 && cleanPin.allSatisfy({ "0123456789".contains($0) }) else {
            return (false, "请输入完整的 6 位数字配对码")
        }
        guard pendingAuthContinuation == nil else {
            return (false, "正在验证配对码，请稍候再试")
        }

        let challengeID = String(UUID().uuidString.prefix(8))
        let payload = "PLK_AUTH_CHALLENGE:\(challengeID)"

        guard let encryptedData = try? CryptoEngine.encrypt(text: payload, pin: cleanPin) else {
            return (false, "本地加密异常")
        }

        return await withCheckedContinuation { continuation in
            self.pendingAuthContinuation = continuation
            self.pendingAuthPIN = cleanPin
            self.pendingChallengeID = challengeID

            peripheral.writeValue(encryptedData, for: characteristic, type: .withResponse)
            self.addLog("🔐 [配对握手] 已向 Windows 发送配对校验挑战: \(challengeID)")

            // 1.8 秒超时拦截
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self, self.pendingChallengeID == challengeID,
                      let cont = self.pendingAuthContinuation else { return }
                self.pendingAuthContinuation = nil
                self.pendingAuthPIN = nil
                self.pendingChallengeID = nil
                self.addLog("❌ [配对握手] 验证超时，未收到电脑确认")
                DispatchQueue.main.async {
                    if PasteLinkStore.shared.getPairingPIN().isEmpty || PasteLinkStore.shared.getPairingPIN() == cleanPin {
                        self.isAuthFailed = true
                    }
                }
                cont.resume(returning: (false, "验证超时，请确认电脑在线、蓝牙连接正常后重试"))
            }
        }
    }

    private func addLog(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let logItem = "[\(formatter.string(from: Date()))] \(msg)"
        logger.info("\(msg)")
        DispatchQueue.main.async {
            self.debugLogs.insert(logItem, at: 0)
            if self.debugLogs.count > 20 {
                self.debugLogs.removeLast()
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            addLog("✅ iPhone 蓝牙已就绪 (poweredOn)")
            if !isManualDisconnect && connectedPeripheral == nil {
                startScanning()
            }
        case .poweredOff:
            statusText = "蓝牙已关闭"
            connectionState = .disconnected
            connectedPeripheral = nil
            connectedDeviceName = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            connectionAttemptID = UUID()
            addLog("❌ iPhone 蓝牙已关闭")
        case .unauthorized:
            statusText = "蓝牙未授权 (请在设置中允许)"
            connectionState = .disconnected
            connectedPeripheral = nil
            connectedDeviceName = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            connectionAttemptID = UUID()
            addLog("❌ 蓝牙权限未授权")
        case .unsupported:
            statusText = "设备不支持 BLE"
            connectionState = .disconnected
            connectedPeripheral = nil
            connectedDeviceName = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            connectionAttemptID = UUID()
            addLog("❌ 设备不支持 BLE")
        case .resetting:
            statusText = "蓝牙正在重置"
            connectionState = .disconnected
            connectedPeripheral = nil
            connectedDeviceName = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            connectionAttemptID = UUID()
            addLog("⚠️ 蓝牙正在重置，等待恢复")
        default:
            statusText = "蓝牙状态未知"
            addLog("⚠️ 蓝牙未知状态: \(central.state.rawValue)")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? "未知设备"
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflowServices = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasOurService = advertisedServices.contains(Self.serviceUUID) || overflowServices.contains(Self.serviceUUID)
        let isPasteLinkProgram = hasOurService || name.localizedCaseInsensitiveContains("pastelink")

        // 仅识别由本程序广播的 PasteLink 电脑，彻底过滤周边所有无关蓝牙设备 (耳机/电视/手环等)
        guard isPasteLinkProgram else {
            return
        }

        addLog("📡 发现 PasteLink 电脑: \(name) (RSSI: \(RSSI))")

        // 将本程序电脑加入/更新到专属设备列表
        DispatchQueue.main.async {
            let device = DiscoveredDevice(
                peripheral: peripheral,
                name: name,
                rssi: RSSI.intValue,
                isPasteLinkCandidate: true
            )
            if let index = self.discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.discoveredDevices[index] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }

        // 若处于扫描状态且非手动断开，自动直连
        if (connectionState == .scanning || connectionState == .disconnected) && !isManualDisconnect && connectedPeripheral == nil {
            addLog("🎯 自动发起连接 PasteLink 电脑: \(name)")
            connect(to: peripheral)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        guard connectedPeripheral?.identifier == peripheral.identifier, !isManualDisconnect else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let name = peripheral.name ?? "Windows 电脑"
        addLog("✅ 已建立 BLE 连接: \(name)，正在发现服务...")

        connectionState = .connecting
        statusText = "已连接，正在配置剪贴板服务..."
        connectedDeviceName = name

        // 发现 PasteLink 服务
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let errDesc = error?.localizedDescription ?? "未知错误"
        addLog("❌ 连接失败: \(errDesc)")
        connectedPeripheral = nil
        connectedDeviceName = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectionAttemptID = UUID()
        connectionState = .disconnected
        statusText = "连接失败: \(errDesc)"

        if !isManualDisconnect { scheduleReconnect(after: 3) }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let name = peripheral.name ?? "设备"
        addLog("⚠️ 与 \(name) 断开连接")
        connectedPeripheral = nil
        connectionAttemptID = UUID()
        connectionState = .disconnected
        statusText = isManualDisconnect ? "已手动断开" : "已断开连接 · 等待重连"
        connectedDeviceName = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        currentTransfer = nil
        writeSemaphore.signal()

        // 仅在非手动断开（如意外掉线、距离过远）时触发自动后台重连
        if !isManualDisconnect {
            scheduleReconnect(after: 2)
        }
    }

    // State Restoration
    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        addLog("🔄 BLE State Restoration 状态恢复")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first
        {
            connectedPeripheral = peripheral
            peripheral.delegate = self
            connectionState = .connecting
            let attemptID = UUID()
            connectionAttemptID = attemptID
            if peripheral.state == .connected {
                statusText = "正在恢复剪贴板服务..."
                connectedDeviceName = peripheral.name
                peripheral.discoverServices([Self.serviceUUID])
                scheduleConnectionTimeout(for: peripheral, attemptID: attemptID)
            } else if peripheral.state == .connecting {
                statusText = "正在恢复连接..."
                scheduleConnectionTimeout(for: peripheral, attemptID: attemptID)
            } else {
                connectedPeripheral = nil
                connectionState = .disconnected
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if let error {
            addLog("❌ 服务发现失败: \(error.localizedDescription)")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            addLog("⚠️ 未在此设备上发现 PasteLink 服务，尝试断开")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        addLog("✅ 找到 PasteLink 服务，正在订阅特征值...")
        peripheral.discoverCharacteristics(
            [Self.clipboardNotifyUUID, Self.clipboardWriteUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              service.uuid == Self.serviceUUID else { return }
        if let error {
            addLog("❌ 特征值发现失败: \(error.localizedDescription)")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        guard let characteristics = service.characteristics,
              let notify = characteristics.first(where: { $0.uuid == Self.clipboardNotifyUUID }),
              let write = characteristics.first(where: { $0.uuid == Self.clipboardWriteUUID }),
              notify.properties.contains(.notify),
              write.properties.contains(.write) else {
            addLog("❌ 剪贴板特征值缺失或不支持所需操作，准备重连")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        notifyCharacteristic = notify
        writeCharacteristic = write
        addLog("📥 发现剪贴板特征值，等待通知订阅确认...")
        if notify.isNotifying {
            finishConnectionIfReady(peripheral)
        } else {
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    private func finishConnectionIfReady(_ peripheral: CBPeripheral) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              peripheral.state == .connected,
              writeCharacteristic != nil, notifyCharacteristic?.isNotifying == true,
              !isManualDisconnect, connectionState != .connected else { return }
        DispatchQueue.main.async {
            guard self.connectedPeripheral?.identifier == peripheral.identifier,
                  peripheral.state == .connected,
                  self.writeCharacteristic != nil,
                  self.notifyCharacteristic?.isNotifying == true,
                  !self.isManualDisconnect, self.connectionState != .connected else { return }
            self.connectionState = .connected
            self.statusText = "✅ 已就绪 (可实时同步)"

            // 若连接到新设备且尚未配置 6 位配对码，自动弹出输入弹窗
            if PasteLinkStore.shared.getPairingPIN().isEmpty {
                self.shouldShowPairingPrompt = true
            } else {
                // 已有安全码，主动发送握手以获取电脑局域网直连 IP/Port
                self.requestLANEndpoint()
            }

            // 检查是否有快捷指令暂存的待发送内容
            let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
            let sendType = defaults.string(forKey: "pendingSendType") ?? "text"
            if sendType == "image",
               let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.pastelink.shared") {
                let pendingImgURL = containerURL.appendingPathComponent("pending_send_image.png")
                if let data = try? Data(contentsOf: pendingImgURL), let img = UIImage(data: data) {
                    try? FileManager.default.removeItem(at: pendingImgURL)
                    defaults.removeObject(forKey: "pendingSendType")
                    self.sendImageToWindows(image: img)
                    self.addLog("📤 [自动同步] 已发送先前快捷指令暂存的图片")
                }
            } else if let pending = defaults.string(forKey: "pendingSendToWindows"), !pending.isEmpty {
                defaults.removeObject(forKey: "pendingSendType")
                defaults.removeObject(forKey: "pendingSendToWindows")
                self.sendToWindows(text: pending)
                self.addLog("📤 [自动同步] 已发送先前快捷指令暂存的内容")
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if characteristic.uuid == Self.clipboardWriteUUID {
            if let error {
                addLog("❌ 发送到 Windows 失败: \(error.localizedDescription)")
            }
            writeSemaphore.signal()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              characteristic.uuid == Self.clipboardNotifyUUID else { return }

        if let error {
            addLog("❌ 接收剪贴板错误: \(error.localizedDescription)")
            return
        }

        guard let rawData = characteristic.value else { return }

        // 检查是否为分片包头部
        if rawData.count >= BLEChunkProtocol.headerSize, rawData.prefix(4) == BLEChunkProtocol.chunkMagic {
            let total = rawData.subdata(in: 5..<7).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let index = rawData.subdata(in: 7..<9).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }

            // 首个切片到达且包含多个切片，若局域网直连可用，立即触发并发极速拉取
            if index == 0 && total > 1 && LANManager.shared.isLanAvailable {
                Task {
                    await self.tryFetchLatestOverLAN()
                }
            }
        }

        // 经过分片重组器进行拼包
        let assembledData = chunkReassembler.process(packet: rawData)

        // 接收进度实时反馈 (分片总数 > 1 时视为大文件/图片分片传输)
        if let progress = chunkReassembler.progress, progress.total > 1 {
            let pct = Int((Double(progress.received) / Double(progress.total)) * 100)
            DispatchQueue.main.async {
                self.currentTransfer = TransferState(
                    direction: .receiving,
                    currentChunk: progress.received,
                    totalChunks: progress.total,
                    progressPercentage: pct,
                    detailText: "\(progress.received)/\(progress.total) 分片 (\(pct)%)"
                )
            }
        }

        guard let data = assembledData else {
            return
        }

        DispatchQueue.main.async {
            self.currentTransfer = nil
        }

        // 1. 优先检查是否处于配对校验握手响应流程中
        if let cont = pendingAuthContinuation, let authPin = pendingAuthPIN, let challengeID = pendingChallengeID {
            // 检查是否为解密失败明文错误包
            if let plain = String(data: data, encoding: .utf8), plain == "PLK_AUTH_FAILED" {
                self.pendingAuthContinuation = nil
                self.pendingAuthPIN = nil
                self.pendingChallengeID = nil
                DispatchQueue.main.async {
                    if PasteLinkStore.shared.getPairingPIN().isEmpty || PasteLinkStore.shared.getPairingPIN() == authPin {
                        self.isAuthFailed = true
                    }
                }
                self.addLog("❌ [配对握手] 电脑端拒绝了该配对码 (解密校验失败)")
                cont.resume(returning: (false, "配对码错误，请核对电脑托盘上的 6 位数字"))
                return
            }

            // 尝试使用候选 PIN 解密握手成功确认包
            if let decrypted = CryptoEngine.decrypt(data: data, pin: authPin),
               decrypted.hasPrefix("PLK_AUTH_SUCCESS:\(challengeID)")
            {
                self.pendingAuthContinuation = nil
                self.pendingAuthPIN = nil
                self.pendingChallengeID = nil
                DispatchQueue.main.async {
                    self.isAuthFailed = false
                }
                PasteLinkStore.shared.savePairingPIN(authPin)
                self.addLog("🎉 [配对握手] 配对校验成功！已建立 AES-256-GCM 信任通道")
                self.extractAndConfigureLAN(from: decrypted)
                LiveActivityManager.shared.startActivityIfConnected(deviceName: self.connectedDeviceName ?? "Windows 电脑", force: true)
                cont.resume(returning: (true, "配对成功！"))
                return
            }
        }

        // 检查电脑端是否主动通知配对失效 / PIN码已变更
        if let plain = String(data: data, encoding: .utf8), plain == "PLK_AUTH_FAILED" {
            addLog("🔑 [配对失效] 电脑端安全码已重置，请重新输入配对码")
            DispatchQueue.main.async {
                self.isAuthFailed = true
                self.shouldShowPairingPrompt = true
            }
            return
        }

        let pin = PasteLinkStore.shared.getPairingPIN()
        guard let decryptedRaw = CryptoEngine.decryptData(data: data, pin: pin), !decryptedRaw.isEmpty else {
            addLog("❌ 接收到无法解密的剪贴板数据 (请核对配对 PIN 码)")
            DispatchQueue.main.async {
                self.isAuthFailed = true
            }
            return
        }

        // 检查是否为电脑握手响应包 (包含局域网 IP / 端口)
        if let text = String(data: decryptedRaw, encoding: .utf8), text.contains("PLK_AUTH_SUCCESS:") {
            self.extractAndConfigureLAN(from: text)
            return
        }

        self.handleDecryptedPayload(decryptedRaw, sourceDescription: "Windows (BLE)")
    }

    /// 尝试通过局域网极速通道并发拉取最新剪贴板载荷
    func tryFetchLatestOverLAN() async {
        guard let encryptedData = await LANManager.shared.fetchLatestOverLAN() else {
            return
        }
        let pin = PasteLinkStore.shared.getPairingPIN()
        guard let decryptedRaw = CryptoEngine.decryptData(data: encryptedData, pin: pin), !decryptedRaw.isEmpty else {
            return
        }

        // 成功获取：立即重置蓝牙分片重组器，丢弃剩余慢速分包
        self.chunkReassembler.reset()

        await MainActor.run {
            self.currentTransfer = TransferState(
                direction: .receiving,
                currentChunk: 1,
                totalChunks: 1,
                progressPercentage: 100,
                detailText: "⚡ 局域网极速直连同步完成 (100%)"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.currentTransfer = nil
            }
        }

        self.handleDecryptedPayload(decryptedRaw, sourceDescription: "局域网极速直连 ⚡")
    }

    /// 解析握手包中透传的 Windows 局域网地址
    func extractAndConfigureLAN(from text: String) {
        guard let range = text.range(of: ":LAN:") else { return }
        let sub = String(text[range.upperBound...])
        let parts = sub.components(separatedBy: ":")
        if parts.count == 2, let port = Int(parts[1]) {
            let ip = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            LANManager.shared.setDiscoveredEndpoint(ip: ip, port: port)
            addLog("⚡ [局域网配置] 电脑直连通道 IP: \(ip):\(port) (经 BLE 握手透传)")
        }
    }

    /// 主动向电脑索取局域网端点
    func requestLANEndpoint() {
        guard connectionState == .connected,
              let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else { return }
        let pin = PasteLinkStore.shared.getPairingPIN()
        guard pin.count == 6 else { return }

        let challengeID = "auto_lan"
        let payload = "PLK_AUTH_CHALLENGE:\(challengeID)"
        guard let encryptedData = try? CryptoEngine.encrypt(text: payload, pin: pin) else { return }
        peripheral.writeValue(encryptedData, for: characteristic, type: .withResponse)
        addLog("📡 [BLE] 已向电脑请求局域网端点对齐")
    }

    /// 处理已解密的剪贴板载荷 (统一供 BLE 重组完成与局域网极速直连拉取共用)
    func handleDecryptedPayload(_ decryptedRaw: Data, sourceDescription: String = "Windows") {
        // 1. 优先检查是否为 PLKI 图像二进制封包
        if let (width, height, pngData) = CryptoEngine.unwrapImagePayload(data: decryptedRaw) {
            guard let uiImage = UIImage(data: pngData) else {
                addLog("⚠️ 收到图片数据但无法解码为 UIImage")
                return
            }

            let item = PasteLinkStore.shared.saveReceivedImage(pngData: pngData, width: Int(width), height: Int(height))

            // 幂等防重：若局域网与蓝牙几乎同时交付同一数据，避免重复震动与弹窗
            if lastProcessedSha256 == item.sha256 {
                return
            }
            lastProcessedSha256 = item.sha256

            addLog("🖼️ [已解密] 收到来自 \(sourceDescription) 的无损图片 (\(width)×\(height), \(pngData.count) 字节) [SHA: \(item.sha256.prefix(8))]")

            DispatchQueue.main.async {
                self.isAuthFailed = false
                self.lastReceivedText = "[图片] \(width)×\(height)"
                self.lastReceivedTime = Date()
                UIPasteboard.general.image = uiImage
            }

            WidgetCenter.shared.reloadAllTimelines()
            LiveActivityManager.shared.showLiveActivity(
                text: "已同步来自电脑的图片 (\(width)×\(height))",
                deviceName: self.connectedDeviceName ?? "Windows 电脑"
            )
            return
        }

        // 2. 否则按 UTF-8 文本处理
        guard let text = String(data: decryptedRaw, encoding: .utf8), !text.isEmpty else {
            addLog("⚠️ 收到非图片且非 UTF-8 文本数据")
            return
        }

        // 过滤内部握手认证包
        if text.hasPrefix("PLK_AUTH_") {
            return
        }

        let item = PasteLinkStore.shared.saveReceivedItem(text: text)
        if lastProcessedSha256 == item.sha256 {
            return
        }
        lastProcessedSha256 = item.sha256

        let preview = text.count > 25 ? String(text.prefix(25)) + "..." : text
        addLog("📋 [已解密] 收到 \(sourceDescription) 剪贴板: \"\(preview)\" (\(decryptedRaw.count)B) [SHA: \(item.sha256.prefix(8))]")

        DispatchQueue.main.async {
            self.isAuthFailed = false
            self.lastReceivedText = text
            self.lastReceivedTime = Date()
            UIPasteboard.general.string = text
        }

        WidgetCenter.shared.reloadAllTimelines()
        LiveActivityManager.shared.showLiveActivity(
            text: text,
            deviceName: self.connectedDeviceName ?? "Windows 电脑"
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              characteristic.uuid == Self.clipboardNotifyUUID else { return }
        if let error {
            addLog("❌ 剪贴板通知订阅失败: \(error.localizedDescription)")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        if characteristic.isNotifying {
            notifyCharacteristic = characteristic
            addLog("🎉 剪贴板通道已建立订阅！")
            finishConnectionIfReady(peripheral)
        } else {
            addLog("⚠️ 剪贴板通道订阅已取消，准备重新连接")
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
}
