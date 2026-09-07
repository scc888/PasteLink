//! Windows 剪贴板监听与写入核心
use std::sync::mpsc::Receiver;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

use crate::core::protocol::{
    calculate_sha256, calculate_sha256_bytes, decode_png_to_rgba, encode_rgba_to_png,
    ClipboardItem, ClipboardPayload,
};
use crate::core::state::AppState;

pub struct ClipboardManager;

impl ClipboardManager {
    /// 启动剪贴板监听后台线程 (支持文字与无损图像双向互通)
    pub fn spawn_listener(
        app_handle: AppHandle,
        state: AppState,
        clip_write_rx: Receiver<ClipboardPayload>,
    ) {
        thread::spawn(move || {
            let mut clipboard = match arboard::Clipboard::new() {
                Ok(cb) => cb,
                Err(e) => {
                    log::error!("[Clipboard] 初始化失败: {}", e);
                    return;
                }
            };

            let mut last_text_hash = String::new();
            let mut last_image_hash = String::new();

            if let Ok(init_text) = clipboard.get_text() {
                if !init_text.is_empty() {
                    let hash = calculate_sha256(&init_text);
                    state.is_duplicate_or_record(&hash);
                    last_text_hash = hash;
                }
            }

            if let Ok(init_img) = clipboard.get_image() {
                if init_img.width > 0 && init_img.height > 0 {
                    if let Ok(png_bytes) = encode_rgba_to_png(
                        init_img.width as u32,
                        init_img.height as u32,
                        &init_img.bytes,
                    ) {
                        let hash = calculate_sha256_bytes(&png_bytes);
                        state.is_duplicate_or_record(&hash);
                        last_image_hash = hash;
                    }
                }
            }

            log::info!("[Clipboard] 监听守护线程已启动 (支持纯文本与无损图像)");

            loop {
                // 1. 处理从 iPhone 接收到的写入请求 (文字或图像)
                while let Ok(incoming) = clip_write_rx.try_recv() {
                    match incoming {
                        ClipboardPayload::Text(iphone_text) => {
                            if iphone_text.is_empty() {
                                continue;
                            }
                            let hash = calculate_sha256(&iphone_text);
                            // 标记为已知 Hash，防止写回时触发二次广播
                            state.is_duplicate_or_record(&hash);

                            if let Err(e) = clipboard.set_text(&iphone_text) {
                                log::error!("[Clipboard] 写入 Windows 剪贴板失败: {}", e);
                            } else {
                                log::info!("[Clipboard ← iPhone] 成功写入系统剪贴板 (文本)");
                            }

                            let item = ClipboardItem::new(iphone_text.clone(), "iphone");
                            state.add_item(item.clone());
                            let _ = app_handle.emit("clipboard-updated", item);
                            last_text_hash = hash;
                        }
                        ClipboardPayload::Image {
                            width,
                            height,
                            png_bytes,
                        } => {
                            let hash = calculate_sha256_bytes(&png_bytes);
                            state.is_duplicate_or_record(&hash);

                            if let Ok((dec_w, dec_h, dec_rgba)) = decode_png_to_rgba(&png_bytes) {
                                let img_data = arboard::ImageData {
                                    width: dec_w as usize,
                                    height: dec_h as usize,
                                    bytes: std::borrow::Cow::from(dec_rgba),
                                };
                                if let Err(e) = clipboard.set_image(img_data) {
                                    log::error!("[Clipboard] 写入 Windows 剪贴板图像失败: {}", e);
                                } else {
                                    log::info!(
                                        "[Clipboard ← iPhone] 成功写入系统剪贴板 (无损图像 {}×{}, {} 字节)",
                                        dec_w,
                                        dec_h,
                                        png_bytes.len()
                                    );
                                }
                            }

                            let item =
                                ClipboardItem::new_image(&png_bytes, width, height, "iphone");
                            state.add_item(item.clone());
                            let _ = app_handle.emit("clipboard-updated", item);
                            last_image_hash = hash;
                        }
                    }
                }

                // 2. 检查本地 Windows 剪贴板图像变化
                if let Ok(img) = clipboard.get_image() {
                    if img.width > 0 && img.height > 0 {
                        if let Ok(png_bytes) = encode_rgba_to_png(
                            img.width as u32,
                            img.height as u32,
                            &img.bytes,
                        ) {
                            let hash = calculate_sha256_bytes(&png_bytes);
                            if hash != last_image_hash {
                                if !state.is_duplicate_or_record(&hash) {
                                    let item = ClipboardItem::new_image(
                                        &png_bytes,
                                        img.width as u32,
                                        img.height as u32,
                                        "windows",
                                    );
                                    state.add_item(item.clone());
                                    let _ = app_handle.emit("clipboard-updated", item);

                                    if !state.is_paused() {
                                        let _ = state.clip_send_tx.try_send(
                                            ClipboardPayload::Image {
                                                width: img.width as u32,
                                                height: img.height as u32,
                                                png_bytes,
                                            },
                                        );
                                        log::info!("[Clipboard → iPhone] 新截图/图片已加入 BLE 广播队列");
                                    } else {
                                        log::info!("[Clipboard] 同步处于暂停状态，已跳过图片广播");
                                    }
                                }
                                last_image_hash = hash;
                            }
                        }
                    }
                }

                // 3. 检查本地 Windows 剪贴板文本变化
                if let Ok(current_text) = clipboard.get_text() {
                    if !current_text.is_empty() {
                        let hash = calculate_sha256(&current_text);
                        if hash != last_text_hash {
                            if !state.is_duplicate_or_record(&hash) {
                                if state.should_ignore_password_manager()
                                    && is_sensitive_clipboard()
                                {
                                    log::info!("[Clipboard 🛡️ 隐私保护] 识别到密码管理器内容，已拦截对外同步");
                                } else {
                                    let item = ClipboardItem::new(current_text.clone(), "windows");
                                    state.add_item(item.clone());
                                    let _ = app_handle.emit("clipboard-updated", item);

                                    if !state.is_paused() {
                                        let _ = state
                                            .clip_send_tx
                                            .try_send(ClipboardPayload::Text(current_text.clone()));
                                        log::info!("[Clipboard → iPhone] 新文本已加入 BLE 广播队列");
                                    } else {
                                        log::info!("[Clipboard] 同步处于暂停状态，已跳过文本广播");
                                    }
                                }
                            }
                            last_text_hash = hash;
                        }
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
