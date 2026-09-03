mod ble;

use anyhow::Result;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tokio::sync::mpsc;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    println!("╔══════════════════════════════════════════╗");
    println!("║       PasteLink Demo · Windows 端        ║");
    println!("║  BLE GATT Server + Clipboard Monitor     ║");
    println!("╚══════════════════════════════════════════╝");
    println!();

    // ── Channel: clipboard thread → main async (clipboard changed) ──
    let (clip_change_tx, mut clip_change_rx) = mpsc::channel::<String>(32);

    // ── Channel: BLE receive → clipboard thread (write to clipboard) ──
    let (clip_write_tx, clip_write_rx) = std::sync::mpsc::channel::<String>();

    // ── 防回环: 记录"我们自己写入"的最后内容 ──
    let last_written_by_us = Arc::new(Mutex::new(String::new()));
    let lwbu_for_thread = last_written_by_us.clone();

    // ── 启动剪贴板监听线程 ──
    thread::spawn(move || {
        let mut clipboard = match arboard::Clipboard::new() {
            Ok(cb) => cb,
            Err(e) => {
                eprintln!("[Clipboard] 初始化失败: {}", e);
                return;
            }
        };

        let mut last_content = clipboard.get_text().unwrap_or_default();
        println!("[Clipboard] 监听已启动 (轮询间隔 300ms)");

        loop {
            // 1. 检查是否有需要写入剪贴板的内容 (来自 iPhone)
            while let Ok(text) = clip_write_rx.try_recv() {
                println!(
                    "[Clipboard ← iPhone] {}",
                    truncate_display(&text, 60)
                );
                *lwbu_for_thread.lock().unwrap() = text.clone();
                if let Err(e) = clipboard.set_text(&text) {
                    eprintln!("[Clipboard] 写入失败: {}", e);
                }
                last_content = text;
            }

            // 2. 轮询剪贴板变化
            if let Ok(current) = clipboard.get_text() {
                if current != last_content && !current.is_empty() {
                    // 检查是否是我们自己刚写入的 (防回环)
                    let written = lwbu_for_thread.lock().unwrap().clone();
                    if current != written {
                        println!(
                            "[Clipboard → BLE] {}",
                            truncate_display(&current, 60)
                        );
                        let _ = clip_change_tx.blocking_send(current.clone());
                    }
                    last_content = current;
                }
            }

            thread::sleep(Duration::from_millis(300));
        }
    });

    // ── 启动 BLE GATT Server (阻塞调用) ──
    let ble_server = match ble::BleServer::start(clip_write_tx) {
        Ok(server) => {
            println!("[BLE] ✅ GATT Server 启动成功");
            println!("[BLE] 等待 iPhone 连接...");
            println!();
            server
        }
        Err(e) => {
            eprintln!();
            eprintln!("╔══════════════════════════════════════════╗");
            eprintln!("║  ❌ BLE 启动失败                        ║");
            eprintln!("╚══════════════════════════════════════════╝");
            eprintln!("错误: {}", e);
            eprintln!();
            eprintln!("可能的原因:");
            eprintln!("  1. 蓝牙适配器未开启或不存在");
            eprintln!("  2. 蓝牙适配器不支持 Peripheral 模式");
            eprintln!("  3. 系统版本低于 Windows 10 1803");
            eprintln!("  4. 需要管理员权限");
            eprintln!();
            eprintln!("请检查蓝牙设置后重试。");
            return Err(e);
        }
    };

    println!("══════════════════════════════════════════");
    println!("  就绪! 在 Windows 上 Ctrl+C 复制内容,");
    println!("  将自动通过 BLE 发送到 iPhone。");
    println!("══════════════════════════════════════════");
    println!();

    // ── 主循环: 剪贴板变化 → BLE 通知 ──
    while let Some(text) = clip_change_rx.recv().await {
        match ble_server.notify_clipboard(&text) {
            Ok(count) => {
                if count > 0 {
                    println!(
                        "[BLE] ✅ 已发送到 {} 台设备: {}",
                        count,
                        truncate_display(&text, 40)
                    );
                } else {
                    println!("[BLE] ⚠️  没有已连接的设备, 内容已缓存");
                }
            }
            Err(e) => {
                eprintln!("[BLE] ❌ 发送失败: {}", e);
            }
        }
    }

    Ok(())
}

/// 截断长文本用于日志显示 (安全处理多字节 UTF-8 中文字符)
fn truncate_display(text: &str, max_chars: usize) -> String {
    let single_line = text.replace('\n', "↵").replace('\r', "");
    let char_count = single_line.chars().count();
    if char_count > max_chars {
        let truncated: String = single_line.chars().take(max_chars).collect();
        format!("\"{}...\" (共{}字符)", truncated, char_count)
    } else {
        format!("\"{}\"", single_line)
    }
}
