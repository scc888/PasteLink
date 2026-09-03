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
use windows::Win32::UI::Shell::{
    SHAppBarMessage, ABM_GETTASKBARPOS, APPBARDATA,
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

    /// 智能将浮窗定位在任务栏与托盘上方（支持多显示器、DPI自适应与任务栏位置探测）
    pub fn position_tray_window(window: &WebviewWindow) {
        if let Ok(Some(monitor)) = window.current_monitor() {
            let screen_size = monitor.size();
            let scale_factor = monitor.scale_factor();
            let win_width = (380.0 * scale_factor) as i32;
            let win_height = (580.0 * scale_factor) as i32;

            let margin_x = (16.0 * scale_factor) as i32;
            let mut margin_y = (56.0 * scale_factor) as i32;

            #[cfg(windows)]
            {
                // 查询 Windows 真实任务栏高度与位置
                let mut app_bar_data = APPBARDATA {
                    cbSize: std::mem::size_of::<APPBARDATA>() as u32,
                    ..Default::default()
                };
                let res = unsafe {
                    SHAppBarMessage(ABM_GETTASKBARPOS, &mut app_bar_data as *mut _ as _)
                };
                if res != 0 {
                    let taskbar_height = (app_bar_data.rc.bottom - app_bar_data.rc.top).abs();
                    if taskbar_height > 0 && taskbar_height < 200 {
                        margin_y = taskbar_height + (10.0 * scale_factor) as i32;
                    }
                }
            }

            let x = (screen_size.width as i32) - win_width - margin_x;
            let y = (screen_size.height as i32) - win_height - margin_y;

            let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition {
                x: x.max(0),
                y: y.max(0),
            }));
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
