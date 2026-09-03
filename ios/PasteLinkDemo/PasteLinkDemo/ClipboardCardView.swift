import SwiftUI

/// 单条剪贴板卡片视图
struct ClipboardCardView: View {
    let item: ClipboardItem
    var onCopy: (ClipboardItem) -> Void
    var onTogglePin: (String) -> Void
    var onDelete: (String) -> Void

    @State private var isCopiedAnimation: Bool = false

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

            // 卡片内容文本
            Text(item.content)
                .font(.subheadline)
                .lineLimit(4)
                .textSelection(.enabled)
                .foregroundStyle(.primary)

            // 卡片底部快捷动作栏
            HStack {
                Spacer()

                // 分享按钮
                ShareLink(item: item.content) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }

                // 一键复制按钮
                Button {
                    triggerCopy()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopiedAnimation ? "checkmark" : "doc.on.clipboard")
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
                Label("复制到系统剪贴板", systemImage: "doc.on.clipboard")
            }

            Button {
                onTogglePin(item.id)
            } label: {
                Label(item.isPinned ? "取消置顶" : "置顶保存", systemImage: item.isPinned ? "pin.slash" : "pin")
            }

            ShareLink(item: item.content) {
                Label("分享内容", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                onDelete(item.id)
            } label: {
                Label("删除", systemImage: "trash")
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
            default:
                EmptyView()
            }
        }
    }

    private func triggerCopy() {
        onCopy(item)
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
