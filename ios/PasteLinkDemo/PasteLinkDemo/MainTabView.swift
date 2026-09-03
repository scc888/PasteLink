import SwiftUI

/// 生产级主 Tab 导航容器
struct MainTabView: View {
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        TabView {
            // Tab 1: 剪贴板流
            ClipboardFeedView(bluetooth: bluetooth)
                .tabItem {
                    Label("剪贴板", systemImage: "doc.on.clipboard.fill")
                }

            // Tab 2: 快捷形态 (Action Button & 灵动岛)
            HardwareIntegrationView()
                .tabItem {
                    Label("快捷形态", systemImage: "button.programmable")
                }

            // Tab 3: 设置与设备管理
            SettingsView(bluetooth: bluetooth)
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .tint(.blue)
    }
}
