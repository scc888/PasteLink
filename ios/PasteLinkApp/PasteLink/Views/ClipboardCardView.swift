import SwiftUI
import Photos

/// 单条剪贴板卡片视图
struct ClipboardCardView: View {
    let item: ClipboardItem
    var transferState: TransferState? = nil
    var onCopy: (ClipboardItem) -> Bool
    var onTogglePin: (String) -> Void
    var onDelete: (String) -> Void

    @State private var isCopiedAnimation: Bool = false
    @State private var cachedImage: UIImage? = nil
    @State private var imageLoadFinished: Bool = false
    @State private var isSavingImage: Bool = false
    @State private var showImageResult: Bool = false
    @State private var imageResultMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 卡片头部：来源、分类、时间与置顶按钮
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: item.source == "windows" ? "desktopcomputer" : "iphone")
                        .font(.caption2)
                    Text(item.source == "windows" ? "来自 Windows" : "来自 iPhone")
                        .font(.caption2.bold())
                }
                .foregroundStyle(item.source == "windows" ? .blue : .green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(item.source == "windows" ? Color.blue.opacity(0.12) : Color.green.opacity(0.12))
                .clipShape(Capsule())

                categoryBadge

                Spacer()

                Text(Date(timeIntervalSince1970: Double(item.timestamp) / 1000), style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // 置顶按钮
                Button {
                    onTogglePin(item.id)
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.caption)
                        .foregroundStyle(item.isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
            }

            // 卡片内容 (支持文本或无损图片缩略图)
            if item.category == "image" {
                VStack(alignment: .leading, spacing: 6) {
                    if let uiImage = cachedImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .background(Color(.tertiarySystemBackground))
                    } else if imageLoadFinished {
                        Label("图片预览不可用，请重新同步", systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        // 异步解码占位骨架，彻底消除主线程阻塞
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.tertiarySystemBackground))
                                .frame(height: 120)
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }

                    // 进度条渲染：当本张图片处于发送/上传中时直接呈现在卡片内
                    if let transfer = transferState {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(transfer.progressPercentage == 100 ? "已同步至 Windows" : "正在发送到电脑...", systemImage: transfer.progressPercentage == 100 ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                                    .font(.caption2.bold())
                                    .foregroundStyle(transfer.progressPercentage == 100 ? .green : .blue)
                                Spacer()
                                Text(transfer.detailText)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(transfer.progressPercentage == 100 ? .green : .blue)
                            }

                            ProgressView(value: Double(transfer.progressPercentage), total: 100)
                                .tint(transfer.progressPercentage == 100 ? .green : .blue)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill((transfer.progressPercentage == 100 ? Color.green : Color.blue).opacity(0.08))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .animation(.easeInOut(duration: 0.2), value: transfer.progressPercentage)
                    }

                    HStack {
                        if let w = item.width, let h = item.height {
                            Text("\(w) × \(h) 像素")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let sz = item.fileSize {
                            Text("无损 PNG · \(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file))")
                                .font(.caption2.bold())
                                .foregroundStyle(.pink)
                        }
                    }
                }
                .task(id: item.sha256) {
                    loadImageAsync()
                }
            } else {
                Text(item.content)
                    .font(.subheadline)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
            }

            // 卡片底部快捷动作栏
            HStack {
                Spacer()

                // 保存到相册 (仅图片类型显示)
                if item.category == "image" {
                    Button {
                        saveImageToPhotosAlbum()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingImage)
                    .accessibilityLabel(isSavingImage ? "正在保存图片" : "保存原图到相册")
                }

                // 分享按钮
                shareAction
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)

                // 一键复制按钮
                Button {
                    triggerCopy()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopiedAnimation ? "checkmark" : (item.category == "image" ? "photo.on.rectangle" : "doc.on.clipboard"))
                            .font(.caption2.bold())
                        Text(isCopiedAnimation ? "已复制" : "复制")
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isCopiedAnimation ? Color.green : Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(item.isPinned ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            triggerCopy()
        }
        .contextMenu {
            Button {
                triggerCopy()
            } label: {
                Label(item.category == "image" ? "复制图片到剪贴板" : "复制到系统剪贴板", systemImage: item.category == "image" ? "photo.on.rectangle" : "doc.on.clipboard")
            }

            if item.category == "image" {
                Button {
                    saveImageToPhotosAlbum()
                } label: {
                    Label("保存图片到系统相册", systemImage: "square.and.arrow.down")
                }
                .disabled(isSavingImage)
            }

            Button {
                onTogglePin(item.id)
            } label: {
                Label(item.isPinned ? "取消置顶" : "置顶保存", systemImage: item.isPinned ? "pin.slash" : "pin")
            }

            shareAction

            Divider()

            Button(role: .destructive) {
                onDelete(item.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .alert("图片操作", isPresented: $showImageResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(imageResultMessage)
        }
    }

    @ViewBuilder
    private var shareAction: some View {
        if item.category == "image" {
            let fileURL = PasteLinkStore.imageFileURL(for: item.sha256)
            let available = FileManager.default.fileExists(atPath: fileURL.path)
            ShareLink(item: fileURL) {
                Label(available ? "分享原图" : "原图不可用，请重新同步", systemImage: "square.and.arrow.up")
            }
            .disabled(!available)
        } else {
            ShareLink(item: item.content) {
                Label("分享内容", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func loadImageAsync() {
        guard item.category == "image" else { return }
        imageLoadFinished = false
        cachedImage = nil

        // 1. 优先从内存缓存中获取 (0ms 极速命中)
        if let memoryCached = ImageCacheManager.shared.image(for: item.sha256) {
            self.cachedImage = memoryCached
            self.imageLoadFinished = true
            return
        }

        // 2. 委托 ImageCacheManager 极速硬件级降采样解码，彻底消除主线程卡顿
        ImageCacheManager.shared.loadThumbnailAsync(for: item) { [id = item.id] image in
            if self.item.id == id {
                self.cachedImage = image
                self.imageLoadFinished = true
            }
        }
    }

    private var categoryBadge: some View {
        Group {
            switch item.category {
            case "url":
                Label("链接", systemImage: "link")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            case "code":
                Label("代码", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            case "image":
                Label("图片", systemImage: "photo")
                    .font(.caption2)
                    .foregroundStyle(.pink)
            default:
                EmptyView()
            }
        }
    }

    private func saveImageToPhotosAlbum() {
        guard !isSavingImage else { return }
        let fileURL = PasteLinkStore.imageFileURL(for: item.sha256)
        guard let fullData = try? Data(contentsOf: fileURL), UIImage(data: fullData) != nil else {
            imageResultMessage = "图片原文件不可用，请重新同步后再保存。"
            showImageResult = true
            return
        }
        isSavingImage = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorization in
            guard authorization == .authorized else {
                DispatchQueue.main.async {
                    isSavingImage = false
                    imageResultMessage = "尚未获得添加照片的权限。请在系统设置中允许 PasteLink 添加照片后重试。"
                    showImageResult = true
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: fullData, options: nil)
            }) { success, _ in
                DispatchQueue.main.async {
                    isSavingImage = false
                    imageResultMessage = success ? "原图已保存到系统相册。" : "图片保存失败，请检查相册权限和设备剩余空间后重试。"
                    showImageResult = true
                }
            }
        }
    }

    private func triggerCopy() {
        // A cached thumbnail is not the original image. Only show success after the owner copied it.
        guard onCopy(item) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            isCopiedAnimation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation {
                isCopiedAnimation = false
            }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        ClipboardCardView(
            item: ClipboardItem(content: "https://github.com/pastelink/app", source: "windows", isPinned: true),
            onCopy: { _ in true },
            onTogglePin: { _ in },
            onDelete: { _ in }
        )
        ClipboardCardView(
            item: ClipboardItem(content: "const token = \"secret_key_12345\";", source: "iphone"),
            onCopy: { _ in true },
            onTogglePin: { _ in },
            onDelete: { _ in }
        )
    }
    .padding()
}
