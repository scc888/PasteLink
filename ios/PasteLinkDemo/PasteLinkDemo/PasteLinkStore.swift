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
    private let maxHistoryCount = 50
    private let maxDedupCount = 60

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? UserDefaults.standard
    }

    @Published var history: [ClipboardItem] = []
    @Published var pairedPIN: String = ""

    private init() {
        self.history = getHistory()
        self.pairedPIN = getPairingPIN()
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

    // MARK: - 配对 PIN 码管理

    func getPairingPIN() -> String {
        defaults.string(forKey: "pairedPIN") ?? ""
    }

    func savePairingPIN(_ pin: String) {
        let clean = pin.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(clean, forKey: "pairedPIN")
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
        if items.count > maxHistoryCount {
            if let lastUnpinnedIndex = items.lastIndex(where: { !$0.isPinned }) {
                items.remove(at: lastUnpinnedIndex)
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

        if items.count > maxHistoryCount {
            if let lastUnpinnedIndex = items.lastIndex(where: { !$0.isPinned }) {
                items.remove(at: lastUnpinnedIndex)
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
