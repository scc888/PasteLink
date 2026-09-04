import CryptoKit
import Foundation

/// 端到端 AES-256-GCM 安全加密中枢 (与 Windows 端完全对齐)
final class CryptoEngine {
    static let shared = CryptoEngine()

    private static let magicHeader = Data([0x50, 0x4C, 0x4B, 0x31]) // "PLK1"
    private static let salt = "PasteLink-ZeroTrust-Salt-v1"

    private init() {}

    /// 从 6 位数字配对码派生 256 位对称密钥
    static func deriveKey(pin: String) -> SymmetricKey {
        let cleanPin = pin.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keyMaterial = salt + cleanPin
        let hash = SHA256.hash(data: Data(keyMaterial.utf8))
        return SymmetricKey(data: hash)
    }

    /// 使用 AES-256-GCM 加密明文
    ///
    /// 数据封装: `[PLK1 (4B)] + [Nonce (12B)] + [密文 + Tag (NB)]`
    static func encrypt(text: String, pin: String) throws -> Data {
        let key = deriveKey(pin: pin)
        let data = Data(text.utf8)
        let nonce = AES.GCM.Nonce()

        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

        var packet = Data()
        packet.append(magicHeader)
        packet.append(contentsOf: sealedBox.nonce)
        packet.append(contentsOf: sealedBox.ciphertext)
        packet.append(contentsOf: sealedBox.tag)

        return packet
    }

    /// 解密数据 (如为明文则平滑降级)
    static func decrypt(data: Data, pin: String) -> String? {
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
                return String(data: decryptedData, encoding: .utf8)
            } catch {
                print("[CryptoEngine] AES-256-GCM 解密失败: \(error)")
                return nil
            }
        } else {
            // 2. 兼容降级明文
            return String(data: data, encoding: .utf8)
        }
    }
}

// MARK: - BLE 分片切片与重组协议 (与 Windows 端对齐: PLKC)

enum BLEChunkProtocol {
    static let chunkMagic = Data([0x50, 0x4C, 0x4B, 0x43]) // "PLKC"
    static let maxPayloadSize = 480

    /// 将大数据密文切片为安全 BLE MTU 分片包
    /// 分片包头格式: `[PLKC (4B)] + [msgId (1B)] + [totalChunks (1B)] + [chunkIndex (1B)] + [flags (1B)] + [payload (<=480B)]`
    static func fragment(data: Data, msgId: UInt8) -> [Data] {
        guard !data.isEmpty else { return [] }
        let totalChunks = UInt8((data.count + maxPayloadSize - 1) / maxPayloadSize)
        var packets: [Data] = []

        for i in 0..<Int(totalChunks) {
            let start = i * maxPayloadSize
            let end = min(start + maxPayloadSize, data.count)
            let slice = data.subdata(in: start..<end)

            var packet = Data()
            packet.append(chunkMagic)
            packet.append(msgId)
            packet.append(totalChunks)
            packet.append(UInt8(i))
            packet.append(0x00) // flags/reserved
            packet.append(slice)
            packets.append(packet)
        }
        return packets
    }
}

/// BLE 分片组包重组器
final class BLEChunkReassembler {
    private var currentMsgId: UInt8 = 0
    private var totalChunks: UInt8 = 0
    private var receivedChunks: [UInt8: Data] = [:]
    private var lastUpdate: Date?

    /// 处理一个收到的分片包。若组包完成则返回完整 Payload，否则返回 nil
    func process(packet: Data) -> Data? {
        // 兼容单包非分片模式 (如直接发送的 PLK1 密文或明文)
        guard packet.count >= 8, packet.prefix(4) == BLEChunkProtocol.chunkMagic else {
            return packet
        }

        let msgId = packet[4]
        let total = packet[5]
        let index = packet[6]
        let payload = packet.subdata(in: 8..<packet.count)

        let now = Date()
        if let last = lastUpdate, now.timeIntervalSince(last) > 4.0 || msgId != currentMsgId {
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
}
