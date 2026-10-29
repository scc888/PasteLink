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

#[cfg(all(test, windows))]
mod clipboard_integration_tests {
    #[test]
    #[ignore = "requires an image already present on the Windows clipboard"]
    fn reads_current_windows_clipboard_image() {
        let mut clipboard = arboard::Clipboard::new().unwrap();
        let image = super::read_clipboard_image(&mut clipboard).expect("clipboard image should be readable");
        assert!(image.width > 0 && image.height > 0);
    }
}

/// Some applications expose PNG under the MIME clipboard format while their DIB
/// cannot be decoded by arboard. Preserve the normal path and use that PNG as a fallback.
fn read_clipboard_image(clipboard: &mut arboard::Clipboard) -> Result<arboard::ImageData<'static>, arboard::Error> {
    match clipboard.get_image() {
        Ok(image) => Ok(image),
        Err(arboard::Error::ClipboardOccupied) => Err(arboard::Error::ClipboardOccupied),
        Err(original) => {
            #[cfg(windows)]
            {
                let format = clipboard_win::register_format("image/png");
                if let Some(format) = format {
                    let guard = clipboard_win::Clipboard::new_attempts(10)
                        .map_err(|_| arboard::Error::ClipboardOccupied)?;
                    if clipboard_win::is_format_avail(format.get()) {
                        let mut png = Vec::new();
                        if let Err(error) = clipboard_win::raw::get_vec(format.get(), &mut png) {
                            log::warn!("[Clipboard] 读取 image/png 格式失败: {}", error);
                        } else {
                            drop(guard);
                            match image::load_from_memory_with_format(&png, image::ImageFormat::Png) {
                                Ok(image) => {
                                    let rgba = image.into_rgba8();
                                    let (width, height) = rgba.dimensions();
                                    log::info!("[Clipboard] 已通过 image/png 格式读取图片 ({}×{})", width, height);
                                    return Ok(arboard::ImageData {
                                        width: width as usize,
                                        height: height as usize,
                                        bytes: std::borrow::Cow::Owned(rgba.into_raw()),
                                    });
                                }
                                Err(error) => log::warn!("[Clipboard] 解码 image/png 格式失败: {}", error),
                            }
                        }
                    }
                }
            }
            Err(original)
        }
    }
}

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
            #[cfg(windows)]
            let mut last_seq = unsafe { windows::Win32::System::DataExchange::GetClipboardSequenceNumber() };

            if let Ok(init_text) = clipboard.get_text() {
                if !init_text.is_empty() {
                    let hash = calculate_sha256(&init_text);
                    state.is_duplicate_or_record(&hash);
                    last_text_hash = hash;
                }
            }

            if let Ok(init_img) = read_clipboard_image(&mut clipboard) {
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

            log::info!("[Clipboard] 监听守护线程已启动 (支持纯文本与无损图像，已启用硬件事件节流)");

            loop {
                // 1. 处理从 iPhone 接收到的写入请求 (文字或图像)
                let mut wrote_from_iphone = false;
                while let Ok(incoming) = clip_write_rx.try_recv() {
                    wrote_from_iphone = true;
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

                #[cfg(windows)]
                let current_seq = unsafe { windows::Win32::System::DataExchange::GetClipboardSequenceNumber() };
                #[cfg(windows)]
                {
                    if current_seq != 0 {
                        let is_same_seq = current_seq == last_seq;
                        if wrote_from_iphone {
                            // 刚刚向系统剪贴板写入了 iPhone 传入的数据，同步序列号并直接跳过当前轮询以防回读
                            last_seq = current_seq;
                            thread::sleep(Duration::from_millis(250));
                            continue;
                        }

                        if is_same_seq {
                            // 核心性能守护：剪贴板序列号未改变，说明系统未发生任何复制事件！
                            // 彻底避免每 250ms 反复对大图片进行高开销的 RGBA 抓取与 Deflate PNG 编码！
                            thread::sleep(Duration::from_millis(250));
                            continue;
                        }
                    } else if wrote_from_iphone {
                        thread::sleep(Duration::from_millis(250));
                        continue;
                    }
                }

                let mut retry_read = false;
                // 2. 检查本地 Windows 剪贴板图像变化
                let image_result = read_clipboard_image(&mut clipboard);
                if matches!(&image_result, Err(arboard::Error::ClipboardOccupied)) {
                    retry_read = true;
                } else if let Err(ref error) = image_result {
                    if !matches!(error, arboard::Error::ContentNotAvailable) {
                        log::warn!("[Clipboard] 读取图片失败: {}", error);
                    }
                }
                if let Ok(img) = image_result {
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
                let text_result = clipboard.get_text();
                if matches!(&text_result, Err(arboard::Error::ClipboardOccupied)) {
                    retry_read = true;
                } else if let Err(ref error) = text_result {
                    if !matches!(error, arboard::Error::ContentNotAvailable) {
                        log::warn!("[Clipboard] 读取文本失败: {}", error);
                    }
                }
                if let Ok(current_text) = text_result {
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

                #[cfg(windows)]
                if !retry_read {
                    last_seq = current_seq;
                }
                if retry_read {
                    log::debug!("[Clipboard] 系统剪贴板暂被占用，将重试本次变化");
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
