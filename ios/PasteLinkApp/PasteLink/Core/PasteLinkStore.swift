import CryptoKit
import Foundation

/// 剪贴板条目数据模型
struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: String
    var content: String
    var source: String // "windows" | "iphone"
    var timestamp: Int64
    var sha256: String
    var preview: String
    var isPinned: Bool
    var category: String // "url" | "code" | "text"

    init(content: String, source: String, isPinned: Bool = false) {
        self.id = UUID().uuidString
        self.content = content
        self.source = source
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        self.sha256 = Self.calculateSHA256(text: content)
        self.preview = Self.makePreview(text: content, maxChars: 120)
        self.isPinned = isPinned
        self.category = Self.detectCategory(text: content)
    }

    static func calculateSHA256(text: String) -> String {
        let inputData = Data(text.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func makePreview(text: String, maxChars: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ↵ ")
        if singleLine.count > maxChars {
            return String(singleLine.prefix(maxChars)) + "..."
        }
        return singleLine
    }

    static func detectCategory(text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("www.") {
            return "url"
        }
        if trimmed.contains("{") && trimmed.contains("}") || trimmed.contains("function") || trimmed.contains("import ") || trimmed.contains("let ") || trimmed.contains("const ") || trimmed.contains("def ") {
            return "code"
        }
        return "text"
    }
}

/// 已配对信任设备模型
struct PairedDevice: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var pairedDate: Date
    var lastSeenDate: Date
    var isConnected: Bool
}

/// App Group 数据共享与防回环持久化中枢
final class PasteLinkStore: ObservableObject {
    static let shared = PasteLinkStore()

    private let appGroupID = "group.com.pastelink.shared"
    private let maxDedupCount = 60

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? UserDefaults.standard
    }

    @Published var history: [ClipboardItem] = []
    @Published var pairedPIN: String = ""
    @Published var maxHistoryCount: Int = 10

    private init() {
        let storedLimit = defaults.integer(forKey: "maxHistoryCount")
        self.maxHistoryCount = storedLimit > 0 ? storedLimit : 10
        self.history = getHistory()
        let pin = getPairingPIN()
        self.pairedPIN = pin.isEmpty ? getLastEnteredPIN() : pin
    }

    // MARK: - 历史记录上限配置

    func setMaxHistoryCount(_ count: Int) {
        let validCount = max(5, count)
        defaults.set(validCount, forKey: "maxHistoryCount")
        DispatchQueue.main.async {
            self.maxHistoryCount = validCount
            self.trimHistoryToLimit()
        }
    }

    private func trimHistoryToLimit() {
        var items = getHistory()
        while items.count > maxHistoryCount {
            if let lastUnpinnedIndex = items.lastIndex(where: { !$0.isPinned }) {
                items.remove(at: lastUnpinnedIndex)
            } else {
                break
            }
        }
        saveHistoryToDisk(items)
    }

    // MARK: - 防回环去重 (SHA-256 Fingerprint Pool)

    /// 检查并记录 Hash (如果已存在返回 true，表示重复/自身回环)
    func isDuplicateOrRecord(sha256: String) -> Bool {
        var hashes = defaults.stringArray(forKey: "dedupHashes") ?? []
        if hashes.contains(sha256) {
            return true
        }
        if hashes.count >= maxDedupCount {
            hashes.removeFirst()
        }
        hashes.append(sha256)
        defaults.set(hashes, forKey: "dedupHashes")
        return false
    }

    // MARK: - 配对 PIN 码管理与最近一次记忆

    func getPairingPIN() -> String {
        if let pin = defaults.string(forKey: "pairedPIN"), !pin.isEmpty {
            return pin
        }
        if let pin = UserDefaults.standard.string(forKey: "pairedPIN"), !pin.isEmpty {
            return pin
        }
        return getLastEnteredPIN()
    }

    func getLastEnteredPIN() -> String {
        if let last = defaults.string(forKey: "lastEnteredPIN"), !last.isEmpty {
            return last
        }
        if let last = UserDefaults.standard.string(forKey: "lastEnteredPIN"), !last.isEmpty {
            return last
        }
        return ""
    }

    func savePairingPIN(_ pin: String) {
        let clean = pin.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 1. 同步保存到 App Group 与 Standard 双通道，确保免证书沙盒环境下也能持久化
        defaults.set(clean, forKey: "pairedPIN")
        defaults.synchronize()
        UserDefaults.standard.set(clean, forKey: "pairedPIN")
        UserDefaults.standard.synchronize()

        // 2. 只要输入过 6 位有效数字，即记录为最近一次输入，防止任何意外清空导致下次重新输入
        if clean.count == 6 {
            defaults.set(clean, forKey: "lastEnteredPIN")
            UserDefaults.standard.set(clean, forKey: "lastEnteredPIN")
        }

        DispatchQueue.main.async {
            self.pairedPIN = clean
        }
    }

    // MARK: - 剪贴板历史流水管理

    @discardableResult
    func saveReceivedItem(text: String) -> ClipboardItem {
        let item = ClipboardItem(content: text, source: "windows")
        _ = isDuplicateOrRecord(sha256: item.sha256)

        // 兼容单文本键值 (供 Intents / Widget 读取)
        defaults.set(text, forKey: "lastReceivedClipboard")
        defaults.set(Date(), forKey: "lastReceivedTime")

        var items = getHistory()
        // 保留收藏项
        let isPreviouslyPinned = items.first(where: { $0.sha256 == item.sha256 })?.isPinned ?? false
        var newItem = item
        newItem.isPinned = isPreviouslyPinned

        items.removeAll { $0.sha256 == item.sha256 }
        items.insert(newItem, at: 0)

        // 限制非置顶条目上限
        while items.count > maxHistoryCount {
            if let lastUnpinnedIndex = items.lastIndex(where: { !$0.isPinned }) {
                items.remove(at: lastUnpinnedIndex)
            } else {
                break
            }
        }

        saveHistoryToDisk(items)
        return newItem
    }

    @discardableResult
    func saveSentItem(text: String) -> ClipboardItem {
        let item = ClipboardItem(content: text, source: "iphone")
        _ = isDuplicateOrRecord(sha256: item.sha256)

        var items = getHistory()
        let isPreviouslyPinned = items.first(where: { $0.sha256 == item.sha256 })?.isPinned ?? false
        var newItem = item
        newItem.isPinned = isPreviouslyPinned

        items.removeAll { $0.sha256 == item.sha256 }
        items.insert(newItem, at: 0)

        while items.count > maxHistoryCount {
            if let lastUnpinnedIndex = items.lastIndex(where: { !$0.isPinned }) {
                items.remove(at: lastUnpinnedIndex)
            } else {
                break
            }
        }

        saveHistoryToDisk(items)
        return newItem
    }

    func togglePin(id: String) {
        var items = getHistory()
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isPinned.toggle()
            saveHistoryToDisk(items)
        }
    }

    func deleteItem(id: String) {
        var items = getHistory()
        items.removeAll { $0.id == id }
        saveHistoryToDisk(items)
    }

    func getHistory() -> [ClipboardItem] {
        guard let data = defaults.data(forKey: "clipboardHistory"),
              let items = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else {
            return []
        }
        return items
    }

    func clearHistory() {
        // 清空时保留置顶项目
        let pinnedItems = getHistory().filter { $0.isPinned }
        saveHistoryToDisk(pinnedItems)
        if pinnedItems.isEmpty {
            defaults.removeObject(forKey: "lastReceivedClipboard")
        }
    }

    private func saveHistoryToDisk(_ items: [ClipboardItem]) {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: "clipboardHistory")
        }
        DispatchQueue.main.async {
            self.history = items
        }
    }
}
