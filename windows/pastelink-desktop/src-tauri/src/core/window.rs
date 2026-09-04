//! Windows 原生视觉增强、DWM 材质、智能任务栏对齐与全局热键唤出
use tauri::{AppHandle, Manager, WebviewWindow};

#[cfg(windows)]
use windows::Win32::Foundation::HWND;
#[cfg(windows)]
use windows::Win32::Graphics::Dwm::{
    DwmSetWindowAttribute, DWMWA_SYSTEMBACKDROP_TYPE, DWMWA_USE_IMMERSIVE_DARK_MODE,
    DWMWA_WINDOW_CORNER_PREFERENCE,
};
#[cfg(windows)]
use windows::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, UnregisterHotKey, MOD_CONTROL, MOD_NOREPEAT, MOD_SHIFT,
};
#[cfg(windows)]
use windows::Win32::UI::WindowsAndMessaging::{
    GetMessageW, MSG, WM_HOTKEY,
};

pub struct WindowEffectManager;

impl WindowEffectManager {
    /// 为无边框浮窗应用 Windows 11 DWM 原生亚克力/云母材质与圆角
    #[cfg(windows)]
    pub fn apply_fluent_effects(window: &WebviewWindow) {
        if let Ok(hwnd_ptr) = window.hwnd() {
            let hwnd = HWND(hwnd_ptr.0 as _);
            unsafe {
                // 1. 设置圆角: DWMWCP_ROUND = 2 (圆角)
                let corner_pref = 2u32;
                let _ = DwmSetWindowAttribute(
                    hwnd,
                    DWMWA_WINDOW_CORNER_PREFERENCE,
                    &corner_pref as *const _ as _,
                    std::mem::size_of::<u32>() as u32,
                );

                // 2. 启用深色沉浸模式（让 DWM 阴影与边框匹配深色系）
                let dark_mode = 1u32;
                let _ = DwmSetWindowAttribute(
                    hwnd,
                    DWMWA_USE_IMMERSIVE_DARK_MODE,
                    &dark_mode as *const _ as _,
                    std::mem::size_of::<u32>() as u32,
                );

                // 3. 设置 Windows 11 原生亚克力/Transient 背景材质 (DWMSBT_TRANSIENTWINDOW = 3, DWMSBT_ACRYLIC = 3)
                let backdrop_type = 3u32;
                let _ = DwmSetWindowAttribute(
                    hwnd,
                    DWMWA_SYSTEMBACKDROP_TYPE,
                    &backdrop_type as *const _ as _,
                    std::mem::size_of::<u32>() as u32,
                );
            }
        }
    }

    #[cfg(not(windows))]
    pub fn apply_fluent_effects(_window: &WebviewWindow) {}

    /// 智能将浮窗定位在主屏幕右下角任务栏托盘正上方（支持多显示器、DPI自适应与屏幕边界严格钳位）
    pub fn position_tray_window(window: &WebviewWindow) {
        // 核心：优先使用系统主显示器 (primary_monitor)！
        // Windows 系统的主要任务栏和托盘时钟始终位于主显示器，彻底杜绝浮窗跨屏跑到副屏！
        let monitor = window
            .primary_monitor()
            .ok()
            .flatten()
            .or_else(|| window.current_monitor().ok().flatten());

        if let Some(monitor) = monitor {
            let scale = monitor.scale_factor();
            let screen_size = monitor.size();
            let screen_pos = monitor.position();

            // 窗口物理像素尺寸
            let win_w = (380.0 * scale) as i32;
            let win_h = (580.0 * scale) as i32;

            // 边距: 右侧保留 16px, 底部为 Windows 任务栏预留 64px
            let margin_x = (16.0 * scale) as i32;
            let margin_y = (64.0 * scale) as i32;

            // 基于主屏幕的原点坐标与物理像素计算右下角位置
            let mut x = screen_pos.x + screen_size.width as i32 - win_w - margin_x;
            let mut y = screen_pos.y + screen_size.height as i32 - win_h - margin_y;

            // 核心安全钳位 (Clamp)：确保窗口完全落在主屏幕视口内，绝对不会飞出屏幕或成为负数
            let min_x = screen_pos.x;
            let max_x = screen_pos.x + (screen_size.width as i32 - win_w).max(0);
            let min_y = screen_pos.y;
            let max_y = screen_pos.y + (screen_size.height as i32 - win_h).max(0);

            x = x.clamp(min_x, max_x);
            y = y.clamp(min_y, max_y);

            let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition { x, y }));
        } else {
            let _ = window.center();
        }
    }

    /// 启动全局快捷键监听 (默认 Ctrl + Shift + V 唤出/隐藏)
    #[cfg(windows)]
    pub fn spawn_global_hotkey_listener(app_handle: AppHandle) {
        std::thread::spawn(move || {
            const HOTKEY_ID: i32 = 0x504C; // 'PL'
            // Ctrl + Shift + V (0x56)
            let registered = unsafe {
                RegisterHotKey(
                    HWND::default(),
                    HOTKEY_ID,
                    MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT,
                    0x56,
                )
            };

            if registered.is_err() {
                log::warn!("[Hotkey] 注册全局快捷键 (Ctrl+Shift+V) 失败或被占用");
                return;
            }

            log::info!("[Hotkey] 全局快捷键 (Ctrl+Shift+V) 注册成功");

            let mut msg = MSG::default();
            unsafe {
                while GetMessageW(&mut msg, HWND::default(), 0, 0).into() {
                    if msg.message == WM_HOTKEY && msg.wParam.0 as i32 == HOTKEY_ID {
                        if let Some(window) = app_handle.get_webview_window("main") {
                            let is_visible = window.is_visible().unwrap_or(false);
                            if is_visible {
                                let _ = window.hide();
                            } else {
                                Self::position_tray_window(&window);
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                    }
                }
                let _ = UnregisterHotKey(HWND::default(), HOTKEY_ID);
            }
        });
    }

    #[cfg(not(windows))]
    pub fn spawn_global_hotkey_listener(_app_handle: AppHandle) {}
}
