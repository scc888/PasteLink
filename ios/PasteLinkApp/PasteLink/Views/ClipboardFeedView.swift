import SwiftUI

/// Tab 1: 跨端传输与剪贴板流水看板
struct ClipboardFeedView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var store = PasteLinkStore.shared

    @State private var searchText: String = ""
    @State private var selectedFilter: FilterType = .all
    @State private var isPairingSheetPresented: Bool = false
    @State private var showToast: Bool = false
    @State private var toastMessage: String = ""
    @State private var showClearConfirm: Bool = false

    enum FilterType: String, CaseIterable, Identifiable {
        case all = "全部"
        case windows = "来自电脑"
        case iphone = "来自手机"
        case pinned = "已置顶"

        var id: String { rawValue }
    }

    var filteredItems: [ClipboardItem] {
        var list = store.history
        switch selectedFilter {
        case .all:
            break
        case .windows:
            list = list.filter { $0.source == "windows" }
        case .iphone:
            list = list.filter { $0.source == "iphone" }
        case .pinned:
            list = list.filter { $0.isPinned }
        }

        if !searchText.isEmpty {
            list = list.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. 顶部设备状态英雄卡片
                    DeviceBannerCard(bluetooth: bluetooth) {
                        isPairingSheetPresented = true
                    }

                    // 2. 分类过滤标签栏
                    filterChipsSection

                    // 3. 快速推送当前剪贴板到 Windows
                    quickSendSection

                    // 4. 历史记录卡片流
                    historyStreamSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("PasteLink")
            .searchable(text: $searchText, prompt: "搜索历史剪贴板内容...")
            .refreshable {
                bluetooth.startScanning()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.history.isEmpty {
                        Button {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                        }
                    }
                }
            }
            .confirmationDialog("确定清空所有未置顶的历史记录？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空历史记录", role: .destructive) {
                    store.clearHistory()
                    triggerToast("🗑️ 历史记录已清空")
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $isPairingSheetPresented) {
                PairingSheet(isPresented: $isPairingSheetPresented) { _ in
                    triggerToast("🔑 配对 PIN 码已更新")
                }
            }
            .onChange(of: bluetooth.shouldShowPairingPrompt) { _, show in
                if show {
                    isPairingSheetPresented = true
                    bluetooth.shouldShowPairingPrompt = false
                }
            }
            .overlay(alignment: .bottom) {
                if showToast {
                    toastView(text: toastMessage)
                }
            }
        }
    }

    // MARK: - 过滤标签栏

    private var filterChipsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilterType.allCases) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFilter = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedFilter == filter ? Color.blue : Color(.secondarySystemBackground))
                            .foregroundStyle(selectedFilter == filter ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - 快速发送当前剪贴板

    private var quickSendSection: some View {
        Button {
            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                bluetooth.sendToWindows(text: clip)
                triggerToast("📤 已加密发送至 Windows")
            } else {
                triggerToast("⚠️ 当前 iPhone 剪贴板为空")
            }
        } label: {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text("发送当前 iPhone 剪贴板到电脑")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text("电脑端直接按 Ctrl+V 即可粘贴")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
            .background(
                LinearGradient(colors: [Color.blue, Color.purple.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.blue.opacity(0.3), radius: 8, y: 4)
        }
        .disabled(bluetooth.connectionState != .connected)
        .opacity(bluetooth.connectionState == .connected ? 1.0 : 0.6)
    }

    // MARK: - 历史流水列表

    private var historyStreamSection: some View {
        VStack(spacing: 12) {
            if filteredItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 24)

                    Text(searchText.isEmpty ? "暂无跨端同步内容" : "未搜索到匹配内容")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("在 Windows 复制内容后将自动在此呈现")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                ForEach(filteredItems) { item in
                    ClipboardCardView(
                        item: item,
                        onCopy: { copied in
                            UIPasteboard.general.string = copied.content
                            let feedback = UINotificationFeedbackGenerator()
                            feedback.prepare()
                            feedback.notificationOccurred(.success)
                            triggerToast("📋 已复制到系统剪贴板")
                        },
                        onTogglePin: { id in
                            store.togglePin(id: id)
                        },
                        onDelete: { id in
                            store.deleteItem(id: id)
                        }
                    )
                }
            }
        }
    }

    private func triggerToast(_ msg: String) {
        toastMessage = msg
        withAnimation {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation {
                showToast = false
            }
        }
    }

    private func toastView(text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.85))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    ClipboardFeedView(bluetooth: BluetoothManager.shared)
}
