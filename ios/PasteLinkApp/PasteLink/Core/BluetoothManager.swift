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

    /// 当前连接状态
    @Published var connectionState: ConnectionState = .disconnected

    /// 状态文本
    @Published var statusText: String = "未连接"

    /// 配对码解密认证是否失败 (提示用户核对 6 位 PIN 码)
    @Published var isAuthFailed: Bool = false

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
        isManualDisconnect = false
        guard centralManager.state == .poweredOn else {
            statusText = "蓝牙未开启"
            addLog("⚠️ 尝试扫描但蓝牙未开启 (状态: \(centralManager.state.rawValue))")
            return
        }

        connectionState = .scanning
        statusText = "正在扫描附近的 PasteLink 电脑..."
        discoveredDevices.removeAll()
        addLog("🔍 开始扫描 PasteLink 电脑...")

        // 注意: Windows BLE 广播可能因包大小限制，在此使用 withServices: nil 全量接收并在发现时严格匹配 PasteLink 专属服务与特征
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // 30 秒超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.connectionState == .scanning else { return }
            self.centralManager.stopScan()
            if self.discoveredDevices.isEmpty {
                self.connectionState = .disconnected
                self.statusText = "未找到 PasteLink 电脑 (请确保电脑端运行)"
                self.addLog("⏱️ 扫描超时，未发现本程序电脑")
            } else {
                self.statusText = "扫描完成，请在下方选择电脑连接"
            }
        }
    }

    /// 手动连接指定设备
    func connect(to peripheral: CBPeripheral) {
        isManualDisconnect = false
        centralManager.stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        let name = peripheral.name ?? "设备"
        statusText = "正在连接 \(name)..."
        addLog("🔗 发起连接: \(name) (\(peripheral.identifier.uuidString.prefix(6)))")

        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }

    /// 断开连接
    func disconnect() {
        isManualDisconnect = true
        centralManager.stopScan()
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            connectionState = .disconnected
            statusText = "已手动断开"
        }
    }

    /// 向 Windows 发送文本 (自动使用 AES-256-GCM 加密与安全 MTU 分片)
    func sendToWindows(text: String) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic
        else {
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
        let msgId = rollingMsgId
        rollingMsgId = rollingMsgId &+ 1
        let chunks = BLEChunkProtocol.fragment(data: encryptedData, msgId: msgId)

        for chunk in chunks {
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        }
        addLog("📤 [分片加密] 已发送 \(encryptedData.count) 字节 (\(chunks.count) 分片) [SHA: \(item.sha256.prefix(8))]")
    }

    /// 向 Windows 发送无损 PNG 图片 (自动使用 PLKI 封装、AES-256-GCM 加密与 BLE 分片)
    func sendImageToWindows(image: UIImage) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic
        else {
            addLog("❌ 发送图片失败: 未连接到电脑或不可写")
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
        let msgId = rollingMsgId
        rollingMsgId = rollingMsgId &+ 1
        let chunks = BLEChunkProtocol.fragment(data: encryptedData, msgId: msgId)

        addLog("📤 [图片推送] 开始向 Windows 推送无损图片 (\(width)×\(height), \(pngData.count) 字节, \(chunks.count) 分片)...")

        // 申请后台任务保活，防止传输中切屏被挂起
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "PasteLinkSendImage") {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for (index, chunk) in chunks.enumerated() {
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                if index % 20 == 0 || index == chunks.count - 1 {
                    let pct = Int((Double(index + 1) / Double(chunks.count)) * 100)
                    self.addLog("📤 [图片推送进度] \(pct)% (\(index + 1)/\(chunks.count) 分片)")
                }
                Thread.sleep(forTimeInterval: 0.008)
            }
            self.addLog("✅ [图片推送完成] 已将无损图片同步至 Windows 剪贴板 [SHA: \(item.sha256.prefix(8))]")
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
            }
        }
    }

    /// 直接发送文本 (供 App Intent / 快捷指令调用，支持异步发送与自动重连排队)
    @discardableResult
    func sendDirectly(text: String) async -> Bool {
        guard connectionState == .connected,
              let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic
        else {
            let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
            defaults.set(text, forKey: "pendingSendToWindows")
            addLog("⚠️ 蓝牙暂未连接，已暂存待发文本")
            if centralManager.state == .poweredOn && connectionState == .disconnected {
                startScanning()
            }
            return false
        }

        let pin = PasteLinkStore.shared.getPairingPIN()
        guard let encryptedData = try? CryptoEngine.encrypt(text: text, pin: pin),
              encryptedData.count <= 10 * 1024 * 1024
        else {
            return false
        }

        let item = PasteLinkStore.shared.saveSentItem(text: text)
        let msgId = rollingMsgId
        rollingMsgId = rollingMsgId &+ 1
        let chunks = BLEChunkProtocol.fragment(data: encryptedData, msgId: msgId)

        for chunk in chunks {
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
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
        guard cleanPin.count == 6 else {
            return (false, "请输入完整的 6 位数字配对码")
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
                guard let self, let cont = self.pendingAuthContinuation else { return }
                self.pendingAuthContinuation = nil
                self.pendingAuthPIN = nil
                self.pendingChallengeID = nil
                self.addLog("❌ [配对握手] 握手超时，配对码不匹配")
                DispatchQueue.main.async {
                    self.isAuthFailed = true
                }
                cont.resume(returning: (false, "配对码错误，请核对电脑上的 6 位数字"))
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
            startScanning()
        case .poweredOff:
            statusText = "蓝牙已关闭"
            connectionState = .disconnected
            addLog("❌ iPhone 蓝牙已关闭")
        case .unauthorized:
            statusText = "蓝牙未授权 (请在设置中允许)"
            connectionState = .disconnected
            addLog("❌ 蓝牙权限未授权")
        case .unsupported:
            statusText = "设备不支持 BLE"
            connectionState = .disconnected
            addLog("❌ 设备不支持 BLE")
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
        let errDesc = error?.localizedDescription ?? "未知错误"
        addLog("❌ 连接失败: \(errDesc)")
        connectionState = .disconnected
        statusText = "连接失败: \(errDesc)"

        // 3 秒后重新扫描
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startScanning()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let name = peripheral.name ?? "设备"
        addLog("⚠️ 与 \(name) 断开连接")
        connectionState = .disconnected
        statusText = isManualDisconnect ? "已手动断开" : "已断开连接 · 等待重连"
        connectedDeviceName = nil
        writeCharacteristic = nil

        // 仅在非手动断开（如意外掉线、距离过远）时触发自动后台重连
        if !isManualDisconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.isManualDisconnect, self.connectionState == .disconnected else { return }
                self.startScanning()
            }
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
            if peripheral.state == .connected {
                connectionState = .connected
                statusText = "已恢复连接"
                connectedDeviceName = peripheral.name
                peripheral.discoverServices([Self.serviceUUID])
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
        if let error {
            addLog("❌ 服务发现失败: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            addLog("⚠️ 未在此设备上发现 PasteLink 服务，尝试断开")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        for service in services where service.uuid == Self.serviceUUID {
            addLog("✅ 找到 PasteLink 服务，正在订阅特征值...")
            peripheral.discoverCharacteristics(
                [Self.clipboardNotifyUUID, Self.clipboardWriteUUID],
                for: service
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            addLog("❌ 特征值发现失败: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            switch char.uuid {
            case Self.clipboardNotifyUUID:
                addLog("📥 发现 Notify 特征值，开启订阅...")
                peripheral.setNotifyValue(true, for: char)

            case Self.clipboardWriteUUID:
                addLog("📤 发现 Write 特征值")
                writeCharacteristic = char

            default:
                break
            }
        }

        DispatchQueue.main.async {
            self.connectionState = .connected
            self.statusText = "✅ 已就绪 (可实时同步)"

            // 若连接到新设备且尚未配置 6 位配对码，自动弹出输入弹窗
            if PasteLinkStore.shared.getPairingPIN().isEmpty {
                self.shouldShowPairingPrompt = true
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
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.clipboardNotifyUUID else { return }

        if let error {
            addLog("❌ 接收剪贴板错误: \(error.localizedDescription)")
            return
        }

        guard let rawData = characteristic.value else { return }

        // 经过分片重组器进行拼包
        guard let data = chunkReassembler.process(packet: rawData) else {
            return
        }

        // 1. 优先检查是否处于配对校验握手响应流程中
        if let cont = pendingAuthContinuation, let authPin = pendingAuthPIN, let challengeID = pendingChallengeID {
            // 检查是否为解密失败明文错误包
            if let plain = String(data: data, encoding: .utf8), plain == "PLK_AUTH_FAILED" {
                self.pendingAuthContinuation = nil
                self.pendingAuthPIN = nil
                self.pendingChallengeID = nil
                DispatchQueue.main.async {
                    self.isAuthFailed = true
                }
                self.addLog("❌ [配对握手] 电脑端拒绝了该配对码 (解密校验失败)")
                cont.resume(returning: (false, "配对码错误，请核对电脑托盘上的 6 位数字"))
                return
            }

            // 尝试使用候选 PIN 解密握手成功确认包
            if let decrypted = CryptoEngine.decrypt(data: data, pin: authPin),
               decrypted == "PLK_AUTH_SUCCESS:\(challengeID)"
            {
                self.pendingAuthContinuation = nil
                self.pendingAuthPIN = nil
                self.pendingChallengeID = nil
                DispatchQueue.main.async {
                    self.isAuthFailed = false
                }
                PasteLinkStore.shared.savePairingPIN(authPin)
                self.addLog("🎉 [配对握手] 配对校验成功！已建立 AES-256-GCM 信任通道")
                cont.resume(returning: (true, "配对成功！"))
                return
            }
        }

        let pin = PasteLinkStore.shared.getPairingPIN()
        guard let decryptedRaw = CryptoEngine.decryptData(data: data, pin: pin), !decryptedRaw.isEmpty else {
            addLog("❌ 接收到无法解密的剪贴板数据 (请核对配对 PIN 码)")
            DispatchQueue.main.async {
                self.isAuthFailed = true
            }
            return
        }

        // 1. 优先检查是否为 PLKI 图像二进制封包
        if let (width, height, pngData) = CryptoEngine.unwrapImagePayload(data: decryptedRaw) {
            guard let uiImage = UIImage(data: pngData) else {
                addLog("⚠️ 收到图片数据但无法解码为 UIImage")
                return
            }

            let item = PasteLinkStore.shared.saveReceivedImage(pngData: pngData, width: Int(width), height: Int(height))
            addLog("🖼️ [已解密] 收到来自 Windows 的无损图片 (\(width)×\(height), \(pngData.count) 字节) [SHA: \(item.sha256.prefix(8))]")

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

        let preview = text.count > 25 ? String(text.prefix(25)) + "..." : text
        let item = PasteLinkStore.shared.saveReceivedItem(text: text)
        addLog("📋 [已解密] 收到 Windows 剪贴板: \"\(preview)\" (\(data.count)B) [SHA: \(item.sha256.prefix(8))]")

        // 1. 更新 UI 属性与剪贴板
        DispatchQueue.main.async {
            self.isAuthFailed = false
            self.lastReceivedText = text
            self.lastReceivedTime = Date()
            UIPasteboard.general.string = text
        }

        // 2. 刷新所有桌面与锁屏小组件
        WidgetCenter.shared.reloadAllTimelines()

        // 3. 触发灵动岛 / 锁屏实时活动 (若用户在快捷形态中开启)
        LiveActivityManager.shared.showLiveActivity(
            text: text,
            deviceName: self.connectedDeviceName ?? "Windows 电脑"
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            addLog("❌ 发送到 Windows 失败: \(error.localizedDescription)")
        } else {
            addLog("✅ 发送到 Windows 成功")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if characteristic.uuid == Self.clipboardNotifyUUID {
            if characteristic.isNotifying {
                addLog("🎉 剪贴板通道已建立订阅！")
            } else {
                addLog("⚠️ 剪贴板通道订阅已取消")
            }
        }
    }
}
