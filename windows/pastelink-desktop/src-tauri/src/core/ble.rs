//! BLE GATT Server 驱动
use anyhow::{Context, Result};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use tauri::{AppHandle, Emitter};
use windows::core::GUID;
use windows::Devices::Bluetooth::GenericAttributeProfile::{
    GattCharacteristicProperties, GattLocalCharacteristic, GattLocalCharacteristicParameters,
    GattProtectionLevel, GattServiceProvider, GattServiceProviderAdvertisingParameters,
    GattWriteRequestedEventArgs,
};
use windows::Devices::Bluetooth::{BluetoothAdapter, BluetoothError};
use windows::Foundation::TypedEventHandler;
use windows::Storage::Streams::{DataReader, DataWriter};

use crate::core::state::AppState;

// ─── UUID 定义 ────────────────────────────────────────────────
pub const SERVICE_UUID: GUID = GUID::from_values(
    0xD7E5A001,
    0x7C8B,
    0x4F9E,
    [0xB8, 0xA3, 0x2C, 0x1D, 0x4E, 0x5F, 0x6A, 0x7B],
);

pub const CLIPBOARD_NOTIFY_UUID: GUID = GUID::from_values(
    0xD7E5A002,
    0x7C8B,
    0x4F9E,
    [0xB8, 0xA3, 0x2C, 0x1D, 0x4E, 0x5F, 0x6A, 0x7B],
);

pub const CLIPBOARD_WRITE_UUID: GUID = GUID::from_values(
    0xD7E5A003,
    0x7C8B,
    0x4F9E,
    [0xB8, 0xA3, 0x2C, 0x1D, 0x4E, 0x5F, 0x6A, 0x7B],
);

pub struct BleServer {
    _provider: GattServiceProvider,
    notify_char: GattLocalCharacteristic,
}

// Windows WinRT 类型是跨线程安全的 COM 对象引用
unsafe impl Send for BleServer {}
unsafe impl Sync for BleServer {}

impl BleServer {
    /// 初始化并启动 BLE GATT 服务
    pub fn start(
        app_handle: AppHandle,
        state: AppState,
        on_receive_tx: Sender<crate::core::protocol::ClipboardPayload>,
    ) -> Result<Self> {
        // 1. 检查蓝牙适配器
        if let Ok(adapter_op) = BluetoothAdapter::GetDefaultAsync() {
            if let Ok(adapter) = adapter_op.get() {
                let is_peripheral = adapter.IsPeripheralRoleSupported().unwrap_or(false);
                let is_le = adapter.IsLowEnergySupported().unwrap_or(false);
                log::info!(
                    "[BLE 硬件] BLE支持: {}, Peripheral广播支持: {}",
                    is_le,
                    is_peripheral
                );
            }
        }

        // 2. 创建 GATT Service Provider
        let provider_result = GattServiceProvider::CreateAsync(SERVICE_UUID)
            .context("CreateAsync 调用失败")?
            .get()
            .context("等待 CreateAsync 结果失败")?;

        let error = provider_result.Error().context("读取错误状态失败")?;
        if error != BluetoothError::Success {
            anyhow::bail!("GATT Service Provider 创建失败: {:?}", error);
        }

        let provider = provider_result
            .ServiceProvider()
            .context("获取 ServiceProvider 失败")?;
        let service = provider.Service().context("获取 Service 失败")?;

        // 3. 创建 Notify Characteristic (Windows → iPhone)
        let notify_char = {
            let params = GattLocalCharacteristicParameters::new()?;
            params.SetCharacteristicProperties(
                GattCharacteristicProperties::Read | GattCharacteristicProperties::Notify,
            )?;
            params.SetReadProtectionLevel(GattProtectionLevel::Plain)?;

            let result = service
                .CreateCharacteristicAsync(CLIPBOARD_NOTIFY_UUID, &params)?
                .get()
                .context("创建 Notify Characteristic 失败")?;

            result
                .Characteristic()
                .context("获取 Notify Characteristic 失败")?
        };

        // 4. 监听 iPhone 连接订阅状态变化
        let state_for_subs = state.clone();
        let app_handle_for_subs = app_handle.clone();
        notify_char.SubscribedClientsChanged(&TypedEventHandler::new(
            move |char: &Option<GattLocalCharacteristic>,
                  _: &Option<windows::core::IInspectable>| {
                if let Some(char) = char {
                    if let Ok(clients) = char.SubscribedClients() {
                        let count = clients.Size().unwrap_or(0);
                        state_for_subs.set_connected_devices(count);
                        let _ = app_handle_for_subs.emit("ble-subscribers-changed", count);
                        log::info!("[BLE] 订阅者数量变化: {}", count);
                    }
                }
                Ok(())
            },
        ))?;

        // 5. 创建 Write Characteristic (iPhone → Windows)
        let write_char = {
            let params = GattLocalCharacteristicParameters::new()?;
            params.SetCharacteristicProperties(
                GattCharacteristicProperties::Write
                    | GattCharacteristicProperties::WriteWithoutResponse,
            )?;
            params.SetWriteProtectionLevel(GattProtectionLevel::Plain)?;

            let result = service
                .CreateCharacteristicAsync(CLIPBOARD_WRITE_UUID, &params)?
                .get()
                .context("创建 Write Characteristic 失败")?;

            result
                .Characteristic()
                .context("获取 Write Characteristic 失败")?
        };

        // 6. 处理来自 iPhone 的写入请求
        let rx_channel = Arc::new(on_receive_tx);
        let state_for_write = state.clone();
        let notify_char_for_write = notify_char.clone();
        let reassembler = Arc::new(std::sync::Mutex::new(crate::core::protocol::ChunkReassembler::new()));

        write_char.WriteRequested(&TypedEventHandler::new(
            move |_char: &Option<GattLocalCharacteristic>,
                  args: &Option<GattWriteRequestedEventArgs>| {
                if let Some(args) = args {
                    let deferral = args.GetDeferral()?;
                    let request = args.GetRequestAsync()?.get()?;
                    let value = request.Value()?;
                    let reader = DataReader::FromBuffer(&value)?;
                    let len = reader.UnconsumedBufferLength()?;

                    if len > 0 {
                        let mut buf = vec![0u8; len as usize];
                        reader.ReadBytes(&mut buf)?;

                        let full_payload_opt = {
                            let mut r = reassembler.lock().unwrap();
                            r.process_packet(&buf)
                        };

                        if let Some(full_payload) = full_payload_opt {
                            let pin = state_for_write.pairing_code.lock().unwrap().clone();
                            let key = crate::core::crypto::CryptoEngine::derive_key(&pin);

                            if let Ok(raw_bytes) = crate::core::crypto::CryptoEngine::decrypt_raw(&full_payload, &key) {
                                if !raw_bytes.is_empty() {
                                    // 1. 优先检查是否为 PLKI 图像二进制封包
                                    if let Some((width, height, png_bytes)) = crate::core::protocol::unwrap_image_payload(&raw_bytes) {
                                        log::info!("[BLE ← iPhone] 收到图片载荷 ({}×{}, {} 字节)", width, height, png_bytes.len());
                                        let _ = rx_channel.send(crate::core::protocol::ClipboardPayload::Image {
                                            width,
                                            height,
                                            png_bytes: png_bytes.to_vec(),
                                        });
                                    } else if let Ok(text) = String::from_utf8(raw_bytes) {
                                        // 2. 检查是否为握手挑战
                                        if text.starts_with("PLK_AUTH_CHALLENGE:") {
                                            let challenge_id = text.strip_prefix("PLK_AUTH_CHALLENGE:").unwrap_or_default();
                                            log::info!("[BLE 🔐 配对握手] 收到来自 iPhone 的配对校验请求: {}", challenge_id);
                                            let local_ip = crate::core::lan::LanServer::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string());
                                            let ack_text = format!("PLK_AUTH_SUCCESS:{}:LAN:{}:52089", challenge_id, local_ip);
                                            if let Ok(ack_packet) = crate::core::crypto::CryptoEngine::encrypt(&ack_text, &key) {
                                                if let Ok(writer) = DataWriter::new() {
                                                    let _ = writer.WriteBytes(&ack_packet);
                                                    if let Ok(buffer) = writer.DetachBuffer() {
                                                        let _ = notify_char_for_write.NotifyValueAsync(&buffer);
                                                        log::info!("[BLE 🔐 配对握手] 已向 iPhone 回复认证成功确认包 (包含局域网高速通道: {}:52089)", local_ip);
                                                    }
                                                }
                                            }
                                        } else {
                                            let _ = rx_channel.send(crate::core::protocol::ClipboardPayload::Text(text));
                                        }
                                    }
                                }
                            } else {
                                log::warn!("[BLE] 收到无效或未授权加密载荷 (配对码不匹配)");
                                let fail_text = "PLK_AUTH_FAILED";
                                if let Ok(writer) = DataWriter::new() {
                                    let _ = writer.WriteBytes(fail_text.as_bytes());
                                    if let Ok(buffer) = writer.DetachBuffer() {
                                        let _ = notify_char_for_write.NotifyValueAsync(&buffer);
                                    }
                                }
                            }
                        }
                    }

                    request.Respond()?;
                    deferral.Complete()?;
                }
                Ok(())
            },
        ))?;

        // 7. 启动 BLE 广播
        let adv_params = GattServiceProviderAdvertisingParameters::new()?;
        adv_params.SetIsDiscoverable(true)?;
        adv_params.SetIsConnectable(true)?;

        if let Err(e) = provider.StartAdvertisingWithParameters(&adv_params) {
            log::warn!("[BLE] 带参广播失败 ({:?})，尝试默认广播...", e);
            provider
                .StartAdvertising()
                .context("启动 BLE 广播失败")?;
        }

        log::info!("[BLE] ✅ GATT Server 成功启动广播");

        Ok(Self {
            _provider: provider,
            notify_char,
        })
    }

    /// 向 iPhone 推送加密剪贴板载荷（支持文本或无损图片，自动安全分包切片与进度反馈）
    pub fn notify_payload(
        &self,
        app_handle: &AppHandle,
        payload: &crate::core::protocol::ClipboardPayload,
        pin: &str,
        state: &crate::core::state::AppState,
    ) -> Result<u32> {
        let subscribers = self.notify_char.SubscribedClients()?;
        let count = subscribers.Size()?;
        if count == 0 {
            return Ok(0);
        }

        let key = crate::core::crypto::CryptoEngine::derive_key(pin);
        let raw_data = match payload {
            crate::core::protocol::ClipboardPayload::Text(text) => text.as_bytes().to_vec(),
            crate::core::protocol::ClipboardPayload::Image { width, height, png_bytes } => {
                crate::core::protocol::wrap_image_payload(png_bytes, *width, *height)
            }
        };

        let encrypted_payload = crate::core::crypto::CryptoEngine::encrypt_raw(&raw_data, &key)
            .map_err(|e| anyhow::anyhow!(e))?;

        if encrypted_payload.len() > 10 * 1024 * 1024 {
            anyhow::bail!("载荷过大 ({} 字节)，限制 10MB", encrypted_payload.len());
        }

        // 将最新密文载荷缓存至 state，供 iPhone 局域网极速直连秒级拉取
        state.set_latest_payload(encrypted_payload.clone());

        use std::sync::atomic::{AtomicU8, Ordering};
        static MSG_COUNTER: AtomicU8 = AtomicU8::new(1);
        let msg_id = MSG_COUNTER.fetch_add(1, Ordering::Relaxed);
        let chunks = crate::core::protocol::fragment_payload(&encrypted_payload, msg_id);
        let total_chunks = chunks.len();
        let is_image = matches!(payload, crate::core::protocol::ClipboardPayload::Image { .. });

        for (idx, chunk) in chunks.iter().enumerate() {
            // 若 iPhone 已通过局域网极速通道拉取完成，立即终止后续慢速蓝牙分片，释放空口信道！
            if state.is_payload_fetched_over_lan() {
                log::info!("[BLE ⚡] iPhone 已通过局域网直连极速获取，成功跳过剩余 {} 个慢速蓝牙分片", total_chunks - idx);
                let _ = app_handle.emit("transfer-progress", serde_json::json!({
                    "is_active": false,
                    "percent": 100,
                    "total_bytes": encrypted_payload.len(),
                    "transferred_chunks": total_chunks,
                    "total_chunks": total_chunks,
                    "item_type": if is_image { "image" } else { "text" },
                    "direction": "send"
                }));
                break;
            }

            let writer = DataWriter::new()?;
            writer.WriteBytes(chunk)?;
            let buffer = writer.DetachBuffer()?;

            self.notify_char
                .NotifyValueAsync(&buffer)?
                .get()
                .context("BLE Notify 投递失败")?;

            if total_chunks > 10 && (idx % 10 == 0 || idx == total_chunks - 1) {
                let percent = ((idx + 1) * 100 / total_chunks) as u32;
                let _ = app_handle.emit("transfer-progress", serde_json::json!({
                    "is_active": idx < total_chunks - 1,
                    "percent": percent,
                    "total_bytes": encrypted_payload.len(),
                    "transferred_chunks": idx + 1,
                    "total_chunks": total_chunks,
                    "item_type": if is_image { "image" } else { "text" },
                    "direction": "send"
                }));
            }

            if chunks.len() > 1 && idx < chunks.len() - 1 {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }

        log::info!(
            "[BLE → iPhone] 已推送数据 ({} 字节, {} 个切片分包)",
            encrypted_payload.len(),
            chunks.len()
        );

        Ok(count)
    }

    /// 向 iPhone 推送文本内容的轻量封装
    pub fn notify_clipboard(&self, app_handle: &AppHandle, text: &str, pin: &str, state: &crate::core::state::AppState) -> Result<u32> {
        self.notify_payload(
            app_handle,
            &crate::core::protocol::ClipboardPayload::Text(text.to_string()),
            pin,
            state,
        )
    }
}
