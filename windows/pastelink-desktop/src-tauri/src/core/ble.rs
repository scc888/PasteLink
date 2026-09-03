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
        on_receive_tx: Sender<String>,
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

                        let pin = state_for_write.pairing_code.lock().unwrap().clone();
                        let key = crate::core::crypto::CryptoEngine::derive_key(&pin);

                        if let Ok(text) = crate::core::crypto::CryptoEngine::decrypt(&buf, &key) {
                            if !text.is_empty() {
                                if text.starts_with("PLK_AUTH_CHALLENGE:") {
                                    let challenge_id = text.strip_prefix("PLK_AUTH_CHALLENGE:").unwrap_or_default();
                                    log::info!("[BLE 🔐 配对握手] 收到来自 iPhone 的配对校验请求: {}", challenge_id);
                                    let ack_text = format!("PLK_AUTH_SUCCESS:{}", challenge_id);
                                    if let Ok(ack_packet) = crate::core::crypto::CryptoEngine::encrypt(&ack_text, &key) {
                                        if let Ok(writer) = DataWriter::new() {
                                            let _ = writer.WriteBytes(&ack_packet);
                                            if let Ok(buffer) = writer.DetachBuffer() {
                                                let _ = notify_char_for_write.NotifyValueAsync(&buffer);
                                                log::info!("[BLE 🔐 配对握手] 已向 iPhone 回复认证成功确认包");
                                            }
                                        }
                                    }
                                } else {
                                    let _ = rx_channel.send(text);
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

    /// 向 iPhone 推送加密剪贴板内容
    pub fn notify_clipboard(&self, text: &str, pin: &str) -> Result<u32> {
        let subscribers = self.notify_char.SubscribedClients()?;
        let count = subscribers.Size()?;
        if count == 0 {
            return Ok(0);
        }

        // 1. 使用 AES-256-GCM 封装加密
        let key = crate::core::crypto::CryptoEngine::derive_key(pin);
        let payload = crate::core::crypto::CryptoEngine::encrypt(text, &key)
            .map_err(|e| anyhow::anyhow!(e))?;

        if payload.len() > 64 * 1024 {
            anyhow::bail!("密文载荷过大 ({} 字节)，限制 64KB", payload.len());
        }

        let writer = DataWriter::new()?;
        writer.WriteBytes(&payload)?;
        let buffer = writer.DetachBuffer()?;

        self.notify_char
            .NotifyValueAsync(&buffer)?
            .get()
            .context("BLE Notify 投递失败")?;

        Ok(count)
    }
}
