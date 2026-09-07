import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// 应用外观主题模式
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }

    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 剪贴板条目数据模型
struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: String
    var content: String
    var source: String // "windows" | "iphone"
    var timestamp: Int64
    var sha256: String
    var preview: String
    var isPinned: Bool
    var category: String // "url" | "code" | "text" | "image"
    var imageData: String? // Base64 data URI (已废弃迁移，仅保留字段兼容旧版 JSON 反序列化)
    var width: Int?
    var height: Int?
    var fileSize: Int?

    init(content: String, source: String, isPinned: Bool = false) {
        self.id = UUID().uuidString
        self.content = content
        self.source = source
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        self.sha256 = Self.calculateSHA256(text: content)
        self.preview = Self.makePreview(text: content, maxChars: 120)
        self.isPinned = isPinned
        self.category = Self.detectCategory(text: content)
        self.imageData = nil
        self.width = nil
        self.height = nil
        self.fileSize = nil
    }

    init(imagePNGData: Data, width: Int, height: Int, source: String, isPinned: Bool = false) {
        self.id = UUID().uuidString
        let sizeDesc = ByteCountFormatter.string(fromByteCount: Int64(imagePNGData.count), countStyle: .file)
        self.content = "[图片] \(width)×\(height) (\(sizeDesc))"
        self.source = source
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let hash = SHA256.hash(data: imagePNGData)
        self.sha256 = hash.compactMap { String(format: "%02x", $0) }.joined()
        self.preview = "[图片] \(width) × \(height) 像素"
        self.isPinned = isPinned
        self.category = "image"
        // 核心优化：彻底废除将数兆 Base64 塞入 UserDefaults 的反模式！
        // 图片二进制由 PasteLinkStore 统一写入沙盒独立文件，此处保持 nil
        self.imageData = nil
        self.width = width
        self.height = height
        self.fileSize = imagePNGData.count
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

    // MARK: - App Group 与磁盘沙盒路径定义
    static let appGroupID = "group.com.pastelink.shared"
    private let maxDedupCount = 60

    private var defaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupID) ?? UserDefaults.standard
    }

    /// App Group 共享容器 URL
    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// 图片独立存储目录 (App Group 共享容器优先，沙盒 Documents 兜底)
    static var imagesDirectoryURL: URL {
        let baseURL: URL
        if let container = sharedContainerURL {
            baseURL = container
        } else {
            baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        }
        let dir = baseURL.appendingPathComponent("images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    /// 获取特定 SHA-256 图片的物理文件存储 URL
    static func imageFileURL(for sha256: String) -> URL {
        return imagesDirectoryURL.appendingPathComponent("\(sha256).png")
    }

    @Published var history: [ClipboardItem] = []
    @Published var pairedPIN: String = ""
    @Published var maxHistoryCount: Int = 10
    @Published var appTheme: AppTheme = .system

    private init() {
        let storedLimit = defaults.integer(forKey: "maxHistoryCount")
        self.maxHistoryCount = storedLimit > 0 ? storedLimit : 10

        let loadedItems = getHistory()
        // 自动迁移旧版本存放在 UserDefaults 中的巨大 Base64 图片到独立沙盒磁盘文件并清理膨胀
        var migratedItems = loadedItems
        var didMigrate = false
        for (i, item) in loadedItems.enumerated() {
            if item.category == "image", let base64URI = item.imageData, !base64URI.isEmpty {
                let base64 = base64URI.hasPrefix("data:image/png;base64,") ?
                    String(base64URI.dropFirst("data:image/png;base64,".count)) : base64URI
                if let rawData = Data(base64Encoded: base64) {
                    let fileURL = Self.imageFileURL(for: item.sha256)
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        try? rawData.write(to: fileURL, options: .atomic)
                    }
                }
                migratedItems[i].imageData = nil
                didMigrate = true
            }
        }

        self.history = migratedItems
        if didMigrate {
            saveHistoryToDisk(migratedItems)
        }

        let pin = getPairingPIN()
        self.pairedPIN = pin.isEmpty ? getLastEnteredPIN() : pin

        let rawTheme = defaults.string(forKey: "appTheme") ?? UserDefaults.standard.string(forKey: "appTheme")
        if let rawTheme = rawTheme, let theme = AppTheme(rawValue: rawTheme) {
            self.appTheme = theme
        } else {
            self.appTheme = .system
        }
    }

    // MARK: - 外观主题切换配置

    func setAppTheme(_ theme: AppTheme) {
        defaults.set(theme.rawValue, forKey: "appTheme")
        defaults.synchronize()
        UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
        UserDefaults.standard.synchronize()

        DispatchQueue.main.async {
            self.appTheme = theme
        }
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
        defaults.set("text", forKey: "lastReceivedType")
        defaults.set(text, forKey: "lastReceivedClipboard")
        defaults.set(Date(), forKey: "lastReceivedTime")

        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let imgURL = containerURL.appendingPathComponent("last_received_image.png")
            try? FileManager.default.removeItem(at: imgURL)
        }

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

    @discardableResult
    func saveReceivedImage(pngData: Data, width: Int, height: Int) -> ClipboardItem {
        let item = ClipboardItem(imagePNGData: pngData, width: width, height: height, source: "windows")
        _ = isDuplicateOrRecord(sha256: item.sha256)

        // 1. 将原图写入独立沙盒磁盘文件，彻底解耦与 UserDefaults 的绑定
        let fileURL = Self.imageFileURL(for: item.sha256)
        try? pngData.write(to: fileURL, options: .atomic)

        // 2. 预热内存图片缓存 (消除滚动卡顿)
        if let img = UIImage(data: pngData) {
            ImageCacheManager.shared.setImage(img, for: item.sha256, cost: pngData.count)
        }

        // 3. 存储共享图片文件与元数据，供 Intents / 快捷指令 / 外部 URL Scheme 读取
        defaults.set("image", forKey: "lastReceivedType")
        defaults.set(width, forKey: "lastReceivedImageWidth")
        defaults.set(height, forKey: "lastReceivedImageHeight")
        defaults.set(Date(), forKey: "lastReceivedTime")
        defaults.removeObject(forKey: "lastReceivedClipboard")

        if let containerURL = Self.sharedContainerURL {
            let imgURL = containerURL.appendingPathComponent("last_received_image.png")
            try? pngData.write(to: imgURL, options: .atomic)
        }

        var items = getHistory()
        let isPreviouslyPinned = items.first(where: { $0.sha256 == item.sha256 })?.isPinned ?? false
        var newItem = item
        newItem.isPinned = isPreviouslyPinned

        items.removeAll { $0.sha256 == item.sha256 }
        items.insert(newItem, at: 0)

        while items.count > maxHistoryCount {
            if let lastUnpinnedIndex = items.lastIndex(where: { !$0.isPinned }) {
                let removed = items.remove(at: lastUnpinnedIndex)
                cleanOrphanImageFile(for: removed, remainingItems: items)
            } else {
                break
            }
        }

        saveHistoryToDisk(items)
        return newItem
    }

    @discardableResult
    func saveSentImage(pngData: Data, width: Int, height: Int) -> ClipboardItem {
        let item = ClipboardItem(imagePNGData: pngData, width: width, height: height, source: "iphone")
        _ = isDuplicateOrRecord(sha256: item.sha256)

        // 1. 将原图写入独立沙盒磁盘文件
        let fileURL = Self.imageFileURL(for: item.sha256)
        try? pngData.write(to: fileURL, options: .atomic)

        // 2. 预热内存图片缓存
        if let img = UIImage(data: pngData) {
            ImageCacheManager.shared.setImage(img, for: item.sha256, cost: pngData.count)
        }

        var items = getHistory()
        let isPreviouslyPinned = items.first(where: { $0.sha256 == item.sha256 })?.isPinned ?? false
        var newItem = item
        newItem.isPinned = isPreviouslyPinned

        items.removeAll { $0.sha256 == item.sha256 }
        items.insert(newItem, at: 0)

        while items.count > maxHistoryCount {
            if let lastUnpinnedIndex = items.lastIndex(where: { !$0.isPinned }) {
                let removed = items.remove(at: lastUnpinnedIndex)
                cleanOrphanImageFile(for: removed, remainingItems: items)
            } else {
                break
            }
        }

        saveHistoryToDisk(items)
        return newItem
    }

    private func cleanOrphanImageFile(for item: ClipboardItem, remainingItems: [ClipboardItem]) {
        guard item.category == "image" else { return }
        let hasReference = remainingItems.contains { $0.sha256 == item.sha256 }
        if !hasReference {
            ImageCacheManager.shared.removeImage(for: item.sha256)
            let fileURL = Self.imageFileURL(for: item.sha256)
            try? FileManager.default.removeItem(at: fileURL)
        }
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
        if let target = items.first(where: { $0.id == id }) {
            items.removeAll { $0.id == id }
            cleanOrphanImageFile(for: target, remainingItems: items)
        }
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
        // 清空时保留置顶项目并清理未引用的磁盘图片
        let items = getHistory()
        let pinnedItems = items.filter { $0.isPinned }

        for item in items where !item.isPinned {
            cleanOrphanImageFile(for: item, remainingItems: pinnedItems)
        }

        saveHistoryToDisk(pinnedItems)
        if pinnedItems.isEmpty {
            defaults.removeObject(forKey: "lastReceivedClipboard")
            ImageCacheManager.shared.clear()
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

// MARK: - 内存图片高性能缓存管理器

/// 内存图片高性能缓存管理器 (消除列表滑动卡顿与反复 Base64/PNG 解码)
final class ImageCacheManager {
    static let shared = ImageCacheManager()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // 最多缓存 50 张历史图片，总大小上限为 120MB 内存
        cache.countLimit = 50
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func image(for sha256: String) -> UIImage? {
        return cache.object(forKey: sha256 as NSString)
    }

    func setImage(_ image: UIImage, for sha256: String, cost: Int = 0) {
        cache.setObject(image, forKey: sha256 as NSString, cost: cost)
    }

    func removeImage(for sha256: String) {
        cache.removeObject(forKey: sha256 as NSString)
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// 高性能异步加载缩略图 (用于 Feed 流无卡顿渲染，使用 CGImageSource 硬件级降采样)
    func loadThumbnailAsync(for item: ClipboardItem, maxPixelSize: CGFloat = 800, completion: @escaping (UIImage?) -> Void) {
        // 1. 优先内存命中 (0ms 极速主线程返回)
        if let cached = image(for: item.sha256) {
            completion(cached)
            return
        }

        // 2. 后台异步降采样解码，彻底避免主线程阻塞
        DispatchQueue.global(qos: .userInitiated).async {
            let fileURL = PasteLinkStore.imageFileURL(for: item.sha256)

            // 优先从磁盘文件加载降采样缩略图
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let thumb = Self.downsample(imageAt: fileURL, maxPixelSize: maxPixelSize) {
                    self.setImage(thumb, for: item.sha256, cost: Int(maxPixelSize * maxPixelSize * 4))
                    DispatchQueue.main.async {
                        completion(thumb)
                    }
                    return
                }
            }

            // 尝试从 last_received_image.png 匹配
            if let container = PasteLinkStore.sharedContainerURL {
                let lastRecvURL = container.appendingPathComponent("last_received_image.png")
                if FileManager.default.fileExists(atPath: lastRecvURL.path),
                   let thumb = Self.downsample(imageAt: lastRecvURL, maxPixelSize: maxPixelSize) {
                    self.setImage(thumb, for: item.sha256, cost: Int(maxPixelSize * maxPixelSize * 4))
                    DispatchQueue.main.async {
                        completion(thumb)
                    }
                    return
                }
            }

            // 兜底兼容旧版 Base64
            if let imgStr = item.imageData {
                let base64 = imgStr.hasPrefix("data:image/png;base64,") ?
                    String(imgStr.dropFirst("data:image/png;base64,".count)) : imgStr
                if let rawData = Data(base64Encoded: base64) {
                    try? rawData.write(to: fileURL, options: .atomic)
                    if let thumb = Self.downsample(imageAt: fileURL, maxPixelSize: maxPixelSize) {
                        self.setImage(thumb, for: item.sha256, cost: Int(maxPixelSize * maxPixelSize * 4))
                        DispatchQueue.main.async {
                            completion(thumb)
                        }
                        return
                    }
                }
            }

            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }

    /// 利用 CGImageSource 进行低内存消耗的硬件级降采样解码
    private static func downsample(imageAt url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary

        guard let downsampled = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }

        return UIImage(cgImage: downsampled)
    }
}
