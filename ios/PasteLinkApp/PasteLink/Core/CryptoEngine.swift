import CryptoKit
import Foundation

/// 端到端 AES-256-GCM 安全加密中枢 (与 Windows 端完全对齐)
final class CryptoEngine {
    static let shared = CryptoEngine()

    private static let magicHeader = Data([0x50, 0x4C, 0x4B, 0x31]) // "PLK1"
    private static let imageMagic = Data([0x50, 0x4C, 0x4B, 0x49])  // "PLKI"
    private static let salt = "PasteLink-ZeroTrust-Salt-v1"

    private init() {}

    /// 从 6 位数字配对码派生 256 位对称密钥
    static func deriveKey(pin: String) -> SymmetricKey {
        let cleanPin = pin.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keyMaterial = salt + cleanPin
        let hash = SHA256.hash(data: Data(keyMaterial.utf8))
        return SymmetricKey(data: hash)
    }

    /// 使用 AES-256-GCM 加密任意二进制数据
    ///
    /// 数据封装: `[PLK1 (4B)] + [Nonce (12B)] + [密文 + Tag (NB)]`
    static func encryptData(data: Data, pin: String) throws -> Data {
        let key = deriveKey(pin: pin)
        let nonce = AES.GCM.Nonce()

        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

        var packet = Data(capacity: 4 + 12 + sealedBox.ciphertext.count + 16)
        packet.append(magicHeader)
        packet.append(contentsOf: sealedBox.nonce)
        packet.append(contentsOf: sealedBox.ciphertext)
        packet.append(contentsOf: sealedBox.tag)

        return packet
    }

    /// 使用 AES-256-GCM 加密明文文本
    static func encrypt(text: String, pin: String) throws -> Data {
        return try encryptData(data: Data(text.utf8), pin: pin)
    }

    /// 解密任意二进制数据 (如为明文则平滑降级)
    static func decryptData(data: Data, pin: String) -> Data? {
        // 1. 检查是否包含 PLK1 加密封包头
        if data.count >= 16 + 4, data.prefix(4) == magicHeader {
            let key = deriveKey(pin: pin)
            let nonceData = data.subdata(in: 4..<16)
            let tagSize = 16
            let cipherLength = data.count - 16 - tagSize
            guard cipherLength >= 0 else { return nil }

            let cipherData = data.subdata(in: 16..<(16 + cipherLength))
            let tagData = data.subdata(in: (16 + cipherLength)..<data.count)

            do {
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData)
                let decryptedData = try AES.GCM.open(sealedBox, using: key)
                return decryptedData
            } catch {
                print("[CryptoEngine] AES-256-GCM 解密失败: \(error)")
                return nil
            }
        } else {
            // 2. 兼容降级明文
            return data
        }
    }

    /// 解密数据并转换为 UTF-8 文本 (如为明文则平滑降级)
    static func decrypt(data: Data, pin: String) -> String? {
        guard let decrypted = decryptData(data: data, pin: pin) else {
            return nil
        }
        return String(data: decrypted, encoding: .utf8)
    }

    // MARK: - PLKI 二进制图像封包包装与解包

    /// 包装图片二进制封包为 PLKI 格式
    /// 结构: `[PLKI (4B)] + [width (4B be)] + [height (4B be)] + [pngData (NB)]`
    static func wrapImagePayload(width: UInt32, height: UInt32, pngData: Data) -> Data {
        var packet = Data(capacity: 12 + pngData.count)
        packet.append(imageMagic)
        var w = width.bigEndian
        packet.append(Data(bytes: &w, count: 4))
        var h = height.bigEndian
        packet.append(Data(bytes: &h, count: 4))
        packet.append(pngData)
        return packet
    }

    /// 解包 PLKI 二进制图片封包
    static func unwrapImagePayload(data: Data) -> (width: UInt32, height: UInt32, pngData: Data)? {
        guard data.count >= 12, data.prefix(4) == imageMagic else {
            return nil
        }
        let width = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let height = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let pngData = data.subdata(in: 12..<data.count)
        return (width, height, pngData)
    }
}

// MARK: - BLE 分片切片与重组协议 (与 Windows 端对齐: PLKC, 10 字节头)

enum BLEChunkProtocol {
    static let chunkMagic = Data([0x50, 0x4C, 0x4B, 0x43]) // "PLKC"
    static let maxPayloadSize = 480
    static let headerSize = 10

    /// 将大数据密文切片为安全 BLE MTU 分片包 (支持最大 65,535 分片，约 30MB)
    /// 分片包头格式: `[PLKC (4B)] + [msgId (1B)] + [totalChunks (2B be)] + [chunkIndex (2B be)] + [flags (1B)] + [payload (<=480B)]`
    static func fragment(data: Data, msgId: UInt8) -> [Data] {
        guard !data.isEmpty else { return [] }
        let total = (data.count + maxPayloadSize - 1) / maxPayloadSize
        guard total <= 65535 else { return [] }
        let totalChunks = UInt16(total)
        var packets: [Data] = []
        packets.reserveCapacity(Int(totalChunks))

        for i in 0..<Int(totalChunks) {
            let start = i * maxPayloadSize
            let end = min(start + maxPayloadSize, data.count)
            let slice = data.subdata(in: start..<end)

            var packet = Data(capacity: headerSize + slice.count)
            packet.append(chunkMagic)
            packet.append(msgId)
            var totalBe = totalChunks.bigEndian
            packet.append(Data(bytes: &totalBe, count: 2))
            var indexBe = UInt16(i).bigEndian
            packet.append(Data(bytes: &indexBe, count: 2))
            packet.append(0x00) // flags
            packet.append(slice)
            packets.append(packet)
        }
        return packets
    }
}

/// BLE 分片组包重组器
final class BLEChunkReassembler {
    private var currentMsgId: UInt8 = 0
    private var totalChunks: UInt16 = 0
    private var receivedChunks: [UInt16: Data] = [:]
    private var lastUpdate: Date?

    /// 处理一个收到的分片包。若组包完成则返回完整 Payload，否则返回 nil
    func process(packet: Data) -> Data? {
        // 兼容单包非分片模式
        guard packet.count >= BLEChunkProtocol.headerSize, packet.prefix(4) == BLEChunkProtocol.chunkMagic else {
            return packet
        }

        let msgId = packet[4]
        let total = packet.subdata(in: 5..<7).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let index = packet.subdata(in: 7..<9).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let payload = packet.subdata(in: 10..<packet.count)

        let now = Date()
        // 分片重组超时设定为 90 秒，保障大尺寸无损 PNG 图片的持续接收
        if let last = lastUpdate, now.timeIntervalSince(last) > 90.0 || msgId != currentMsgId {
            receivedChunks.removeAll()
        }

        currentMsgId = msgId
        totalChunks = total
        lastUpdate = now
        receivedChunks[index] = payload

        if receivedChunks.count == Int(total) {
            var fullData = Data()
            for i in 0..<total {
                if let part = receivedChunks[i] {
                    fullData.append(part)
                } else {
                    return nil
                }
            }
            receivedChunks.removeAll()
            lastUpdate = nil
            return fullData
        }

        return nil
    }

    /// 获取当前拼包进度 (已收到切片数, 总切片数)
    var progress: (received: Int, total: Int)? {
        guard totalChunks > 0 else { return nil }
        return (receivedChunks.count, Int(totalChunks))
    }
}
