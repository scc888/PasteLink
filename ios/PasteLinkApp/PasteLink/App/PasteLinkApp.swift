import ActivityKit
import SwiftUI

/// PasteLink iOS 生产级应用程序入口
///
/// @author PasteLink Team
/// @date 2026-09-02
@main
struct PasteLinkApp: App {
    @StateObject private var bluetoothManager = BluetoothManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(bluetoothManager)
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        // 保证前台激活时灵动岛通道就绪
                        LiveActivityManager.shared.ensureActivityStarted()
                    }
                }
                .onOpenURL { url in
                    // 处理快捷指令外部跳转
                    if url.scheme == "shortcuts" || url.absoluteString.hasPrefix("shortcuts://") {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        return
                    }

                    // 处理 pastelink:// 自定义 URL Scheme
                    if url.scheme == "pastelink" {
                        if url.host == "copy" || url.path == "/copy" {
                            let defaults = UserDefaults(suiteName: "group.com.pastelink.shared") ?? UserDefaults.standard
                            if let text = defaults.string(forKey: "lastReceivedClipboard"), !text.isEmpty {
                                UIPasteboard.general.string = text
                                let generator = UINotificationFeedbackGenerator()
                                generator.prepare()
                                generator.notificationOccurred(.success)
                            }
                        } else if url.host == "push" || url.path == "/push" {
                            if let clipText = UIPasteboard.general.string, !clipText.isEmpty {
                                bluetoothManager.sendToWindows(text: clipText)
                            }
                        }
                    }
                }
        }
    }
}
