import SwiftUI

/// PasteLink Demo 入口
///
/// @author PasteLink
/// @date 2026-09-01
@main
struct PasteLinkDemoApp: App {
    @StateObject private var bluetoothManager = BluetoothManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetoothManager)
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        // 保证前台激活时灵动岛状态与连接状态对齐：已连接常驻，未连接自动退出
                        LiveActivityManager.shared.ensureActivityStarted()
                    }
                }
                .onOpenURL { url in
                    // 处理 pastelink 自定义直达协议
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
