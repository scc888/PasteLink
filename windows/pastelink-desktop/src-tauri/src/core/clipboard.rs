//! Windows 剪贴板监听与写入核心
use std::sync::mpsc::Receiver;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

use crate::core::protocol::{calculate_sha256, ClipboardItem};
use crate::core::state::AppState;

pub struct ClipboardManager;

impl ClipboardManager {
    /// 启动剪贴板监听后台线程
    pub fn spawn_listener(
        app_handle: AppHandle,
        state: AppState,
        clip_write_rx: Receiver<String>,
    ) {
        thread::spawn(move || {
            let mut clipboard = match arboard::Clipboard::new() {
                Ok(cb) => cb,
                Err(e) => {
                    log::error!("[Clipboard] 初始化失败: {}", e);
                    return;
                }
            };

            let mut last_content = clipboard.get_text().unwrap_or_default();
            if !last_content.is_empty() {
                let init_hash = calculate_sha256(&last_content);
                state.is_duplicate_or_record(&init_hash);
            }

            log::info!("[Clipboard] 监听守护线程已启动");

            loop {
                // 1. 处理从 iPhone 接收到的文本写入请求
                while let Ok(iphone_text) = clip_write_rx.try_recv() {
                    if iphone_text.is_empty() {
                        continue;
                    }

                    let hash = calculate_sha256(&iphone_text);
                    // 标记为已知 Hash，防止写回时触发二次广播
                    state.is_duplicate_or_record(&hash);

                    if let Err(e) = clipboard.set_text(&iphone_text) {
                        log::error!("[Clipboard] 写入 Windows 剪贴板失败: {}", e);
                    } else {
                        log::info!("[Clipboard ← iPhone] 成功写入系统剪贴板");
                    }

                    let item = ClipboardItem::new(iphone_text.clone(), "iphone");
                    state.add_item(item.clone());
                    let _ = app_handle.emit("clipboard-updated", item);
                    last_content = iphone_text;
                }

                // 2. 检查本地 Windows 剪贴板变化
                if let Ok(current_text) = clipboard.get_text() {
                    if current_text != last_content && !current_text.is_empty() {
                        let hash = calculate_sha256(&current_text);

                        // 如果是非自身回环产生的新复制内容
                        if !state.is_duplicate_or_record(&hash) {
                            // 检查是否为密码管理器敏感内容
                            if state.should_ignore_password_manager() && is_sensitive_clipboard() {
                                log::info!("[Clipboard 🛡️ 隐私保护] 识别到密码管理器内容，已拦截对外同步");
                            } else {
                                let item = ClipboardItem::new(current_text.clone(), "windows");
                                state.add_item(item.clone());
                                let _ = app_handle.emit("clipboard-updated", item);

                                // 如果未暂停同步，发送至 BLE 广播通道
                                if !state.is_paused() {
                                    let _ = state.clip_send_tx.try_send(current_text.clone());
                                    log::info!("[Clipboard → iPhone] 新内容已加入 BLE 广播队列");
                                } else {
                                    log::info!("[Clipboard] 同步处于暂停状态，已跳过广播");
                                }
                            }
                        }
                        last_content = current_text;
                    }
                }

                thread::sleep(Duration::from_millis(250));
            }
        });
    }
}

/// 检查当前剪贴板是否携带密码管理器/隐私避让标记
#[cfg(windows)]
fn is_sensitive_clipboard() -> bool {
    use windows::core::w;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::System::DataExchange::{
        CloseClipboard, IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW,
    };

    unsafe {
        if OpenClipboard(HWND::default()).is_ok() {
            let ignore_format1 = RegisterClipboardFormatW(w!("Clipboard Viewer Ignore"));
            let ignore_format2 =
                RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing"));
            let ignore_format3 = RegisterClipboardFormatW(w!("1Password: Private Data"));

            let is_ignored = (ignore_format1 != 0
                && IsClipboardFormatAvailable(ignore_format1).is_ok())
                || (ignore_format2 != 0 && IsClipboardFormatAvailable(ignore_format2).is_ok())
                || (ignore_format3 != 0 && IsClipboardFormatAvailable(ignore_format3).is_ok());

            let _ = CloseClipboard();
            return is_ignored;
        }
    }
    false
}

#[cfg(not(windows))]
fn is_sensitive_clipboard() -> bool {
    false
}
