pub mod core;

use std::sync::Arc;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::sync::mpsc;

use crate::core::ble::BleServer;
use crate::core::clipboard::ClipboardManager;
use crate::core::state::{AppState, StatusPayload};
use crate::core::window::WindowEffectManager;

// ─── Tauri Commands ──────────────────────────────────────────

#[tauri::command]
fn get_status(state: State<'_, AppState>) -> StatusPayload {
    state.get_status_payload()
}

#[tauri::command]
fn toggle_pause(state: State<'_, AppState>, app: AppHandle, paused: bool) -> bool {
    state.set_paused(paused);
    let _ = app.emit("pause-state-changed", paused);
    paused
}

#[tauri::command]
fn copy_to_system_clipboard(state: State<'_, AppState>, text: String) -> Result<(), String> {
    if text.is_empty() {
        return Ok(());
    }
    let hash = crate::core::protocol::calculate_sha256(&text);
    state.is_duplicate_or_record(&hash);

    let mut cb = arboard::Clipboard::new().map_err(|e| e.to_string())?;
    cb.set_text(&text).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn copy_item_by_id(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let item_opt = {
        let items = state.recent_items.lock().unwrap();
        items.iter().find(|i| i.id == id).cloned()
    };

    if let Some(item) = item_opt {
        state.is_duplicate_or_record(&item.sha256);
        let mut cb = arboard::Clipboard::new().map_err(|e| e.to_string())?;

        if item.item_type == "image" {
            if let Some(ref data_url) = item.image_data {
                if let Some(b64) = data_url.strip_prefix("data:image/png;base64,") {
                    use base64::Engine;
                    let png_bytes = base64::engine::general_purpose::STANDARD
                        .decode(b64)
                        .map_err(|e| format!("Base64 解码失败: {}", e))?;

                    let (w, h, rgba) = crate::core::protocol::decode_png_to_rgba(&png_bytes)?;
                    cb.set_image(arboard::ImageData {
                        width: w as usize,
                        height: h as usize,
                        bytes: std::borrow::Cow::from(rgba),
                    })
                    .map_err(|e| e.to_string())?;
                    return Ok(());
                }
            }
            return Err("图像数据缺失".to_string());
        } else {
            cb.set_text(&item.content).map_err(|e| e.to_string())?;
            return Ok(());
        }
    }
    Err("未找到指定历史条目".to_string())
}

#[tauri::command]
fn clear_history(state: State<'_, AppState>, app: AppHandle) {
    state.clear_history();
    let _ = app.emit("history-cleared", ());
}

#[tauri::command]
fn delete_history_item(state: State<'_, AppState>, app: AppHandle, id: String) {
    state.delete_item(&id);
    let _ = app.emit("history-item-deleted", id);
}

#[tauri::command]
fn toggle_pin_history_item(state: State<'_, AppState>, app: AppHandle, id: String) -> bool {
    let is_pinned = state.toggle_pin_item(&id);
    let _ = app.emit("history-item-pinned", serde_json::json!({ "id": id, "is_pinned": is_pinned }));
    is_pinned
}

#[tauri::command]
fn refresh_pairing_pin(state: State<'_, AppState>) -> String {
    let new_pin = AppState::generate_pin();
    *state.pairing_code.lock().unwrap() = new_pin.clone();
    state.persist_current_settings();
    new_pin
}

#[tauri::command]
fn toggle_ignore_password_manager(state: State<'_, AppState>, app: AppHandle, ignore: bool) -> bool {
    state.set_ignore_password_manager(ignore);
    let _ = app.emit("ignore-password-manager-changed", ignore);
    ignore
}

#[tauri::command]
fn toggle_autostart(app: AppHandle, enabled: bool) -> Result<bool, String> {
    crate::core::autostart::AutoStartManager::set_enabled(enabled)?;
    let _ = app.emit("autostart-changed", enabled);
    Ok(enabled)
}

#[tauri::command]
fn hide_window(app: AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.hide();
    }
}

// ─── Tauri App 生命周期与托盘初始化 ─────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if let Ok(file) = std::fs::File::create("D:\\PasteLink\\pastelink.log") {
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .target(env_logger::Target::Pipe(Box::new(file)))
            .try_init();
    }

    // 1. 创建跨模块 Channel
    // Channel: 剪贴板变化 (Windows) -> BLE Notify 异步发送
    let (clip_send_tx, mut clip_send_rx) =
        mpsc::channel::<crate::core::protocol::ClipboardPayload>(64);
    // Channel: BLE Write (iPhone) -> 剪贴板写入线程
    let (clip_write_tx, clip_write_rx) =
        std::sync::mpsc::channel::<crate::core::protocol::ClipboardPayload>();

    let app_state = AppState::new(clip_send_tx);

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(app_state.clone())
        .invoke_handler(tauri::generate_handler![
            get_status,
            toggle_pause,
            toggle_ignore_password_manager,
            toggle_autostart,
            copy_to_system_clipboard,
            copy_item_by_id,
            clear_history,
            delete_history_item,
            toggle_pin_history_item,
            refresh_pairing_pin,
            hide_window,
        ])
        .setup({
            let state = app_state.clone();
            move |app| {
                let app_handle = app.handle().clone();

                // 2. 启动 Windows 剪贴板守护监听
                ClipboardManager::spawn_listener(
                    app_handle.clone(),
                    state.clone(),
                    clip_write_rx,
                );

                // 2.5 启动局域网极速直连服务 (HTTP REST API + UDP 自动发现)
                crate::core::lan::LanServer::start(
                    app_handle.clone(),
                    state.clone(),
                    clip_write_tx.clone(),
                );

                // 3. 启动 BLE GATT Server
                let state_for_ble = state.clone();
                let app_for_ble = app_handle.clone();
                std::thread::spawn(move || {
                    match BleServer::start(app_for_ble.clone(), state_for_ble.clone(), clip_write_tx) {
                        Ok(server) => {
                            log::info!("[BLE] GATT 服务就绪，等待 iPhone 连接...");
                            let server = Arc::new(server);
                            // 监听本地剪贴板发送通道
                            let rt = tokio::runtime::Builder::new_current_thread()
                                .enable_all()
                                .build()
                                .unwrap();

                            rt.block_on(async move {
                                while let Some(payload) = clip_send_rx.recv().await {
                                    let pin = state_for_ble.pairing_code.lock().unwrap().clone();
                                    if let Err(e) = server.notify_payload(&app_for_ble, &payload, &pin, &state_for_ble) {
                                        log::warn!("[BLE] 广播推送异常: {}", e);
                                    }
                                }
                            });
                        }
                        Err(e) => {
                            log::error!("[BLE] GATT 服务启动失败: {}", e);
                        }
                    }
                });

                // 4. 应用 Windows 11 DWM 亚克力/云母模糊材质与圆角
                if let Some(window) = app.get_webview_window("main") {
                    WindowEffectManager::apply_fluent_effects(&window);
                }

                // 5. 启动全局快捷键监听 (Ctrl + Shift + V)
                WindowEffectManager::spawn_global_hotkey_listener(app_handle.clone());

                // 6. 构建系统托盘菜单
                let show_item = MenuItemBuilder::with_id("show", "打开控制面板 (Ctrl+Shift+V)").build(app)?;
                let pause_item = MenuItemBuilder::with_id("toggle_pause", "暂停/恢复同步").build(app)?;
                let quit_item = MenuItemBuilder::with_id("quit", "退出 PasteLink").build(app)?;

                let menu = MenuBuilder::new(app)
                    .item(&show_item)
                    .item(&pause_item)
                    .separator()
                    .item(&quit_item)
                    .build()?;

                // 7. 构建托盘图标
                if let Some(icon) = app.default_window_icon().cloned() {
                    let tray = TrayIconBuilder::new()
                        .icon(icon)
                        .tooltip("PasteLink - 跨设备极速剪贴板 (Ctrl+Shift+V)")
                        .menu(&menu)
                        .on_menu_event({
                            let state = state.clone();
                            move |app, event| match event.id.as_ref() {
                                "show" => {
                                    if let Some(window) = app.get_webview_window("main") {
                                        WindowEffectManager::position_tray_window(&window);
                                        let _ = window.show();
                                        let _ = window.set_focus();
                                    }
                                }
                                "toggle_pause" => {
                                    let new_state = !state.is_paused();
                                    state.set_paused(new_state);
                                    let _ = app.emit("pause-state-changed", new_state);
                                }
                                "quit" => {
                                    app.exit(0);
                                }
                                _ => {}
                            }
                        })
                        .on_tray_icon_event(move |tray, event| {
                            if let TrayIconEvent::Click {
                                button: MouseButton::Left,
                                button_state: MouseButtonState::Up,
                                ..
                            } = event
                            {
                                let app = tray.app_handle();
                                if let Some(window) = app.get_webview_window("main") {
                                    if window.is_visible().unwrap_or(false) {
                                        let _ = window.hide();
                                    } else {
                                        WindowEffectManager::position_tray_window(&window);
                                        let _ = window.show();
                                        let _ = window.set_focus();
                                    }
                                }
                            }
                        })
                        .build(app)?;

                    let _ = tray;
                }

                // 8. 应用启动时主动定位并呈递窗口，让用户立刻看到界面
                if let Some(window) = app.get_webview_window("main") {
                    WindowEffectManager::position_tray_window(&window);
                    let _ = window.show();
                    let _ = window.set_focus();
                }

                Ok(())
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|_app_handle, event| {
        if let tauri::RunEvent::ExitRequested { api, .. } = event {
            api.prevent_exit();
        }
    });
}
