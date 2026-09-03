//! BLE GATT Server 模块
//!
//! 使用 Windows.Devices.Bluetooth.GenericAttributeProfile API
//! 创建一个 BLE Peripheral, 对外暴露 PasteLink 剪贴板服务。
//!
//! 服务结构:
//!   Service: D7E5A001-7C8B-4F9E-B8A3-2C1D4E5F6A7B
//!     ├── Clipboard Notify Char: D7E5A002-...  (Read + Notify, W→iPhone)
//!     └── Clipboard Write Char:  D7E5A003-...  (Write, iPhone→W)
//!
//! 注意: windows crate 0.58 的 IAsyncOperation 不实现 Future trait,
//! 因此使用 .get() 阻塞等待 WinRT 异步操作完成。

use anyhow::{Context, Result};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use windows::core::GUID;
use windows::Devices::Bluetooth::{BluetoothAdapter, BluetoothError};
use windows::Devices::Bluetooth::GenericAttributeProfile::{
    GattCharacteristicProperties, GattLocalCharacteristic, GattLocalCharacteristicParameters,
    GattProtectionLevel, GattServiceProvider, GattServiceProviderAdvertisingParameters,
    GattWriteRequestedEventArgs,
};
use windows::Foundation::TypedEventHandler;
use windows::Storage::Streams::{DataReader, DataWriter};

// ─── 自定义 UUID ──────────────────────────────────────────────
// PasteLink Service
const SERVICE_UUID: GUID = GUID::from_values(
    0xD7E5A001,
    0x7C8B,
    0x4F9E,
    [0xB8, 0xA3, 0x2C, 0x1D, 0x4E, 0x5F, 0x6A, 0x7B],
);

// Windows → iPhone (Read + Notify)
const CLIPBOARD_NOTIFY_UUID: GUID = GUID::from_values(
    0xD7E5A002,
    0x7C8B,
    0x4F9E,
    [0xB8, 0xA3, 0x2C, 0x1D, 0x4E, 0x5F, 0x6A, 0x7B],
);

// iPhone → Windows (Write)
const CLIPBOARD_WRITE_UUID: GUID = GUID::from_values(
    0xD7E5A003,
    0x7C8B,
    0x4F9E,
    [0xB8, 0xA3, 0x2C, 0x1D, 0x4E, 0x5F, 0x6A, 0x7B],
);

/// BLE GATT Server 封装
pub struct BleServer {
    _provider: GattServiceProvider,
    notify_char: GattLocalCharacteristic,
}

impl BleServer {
    /// 启动 BLE GATT Server (阻塞调用)
    ///
    /// # 参数
    /// - `on_receive_tx`: 当 iPhone 发来数据时, 通过此 channel 传给剪贴板线程
    pub fn start(on_receive_tx: Sender<String>) -> Result<Self> {
        // ── 检查蓝牙适配器硬件能力 ──
        if let Ok(adapter_op) = BluetoothAdapter::GetDefaultAsync() {
            if let Ok(adapter) = adapter_op.get() {
                let is_peripheral = adapter.IsPeripheralRoleSupported().unwrap_or(false);
                let is_central = adapter.IsCentralRoleSupported().unwrap_or(false);
                let is_le = adapter.IsLowEnergySupported().unwrap_or(false);
                println!("[BLE 适配器] BLE支持: {}, 外设广播(Peripheral): {}, 主机(Central): {}", is_le, is_peripheral, is_central);
                if !is_peripheral {
                    println!("[BLE ⚠️ 提示] 当前蓝牙适配器汇报不支持外设模式，但 Windows 仍会尝试广播");
                }
            }
        }

        // ── 创建 Service Provider ──
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

        // ── 创建 Notify Characteristic (Windows → iPhone) ──
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

        // ── 监听订阅者变化 ──
        notify_char.SubscribedClientsChanged(&TypedEventHandler::new(
            |char: &Option<GattLocalCharacteristic>,
             _: &Option<windows::core::IInspectable>| {
                if let Some(char) = char {
                    if let Ok(clients) = char.SubscribedClients() {
                        if let Ok(count) = clients.Size() {
                            println!("[BLE] 订阅者数量变更: {}", count);
                        }
                    }
                }
                Ok(())
            },
        ))?;

        // ── 创建 Write Characteristic (iPhone → Windows) ──
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

        // ── 处理来自 iPhone 的写入请求 ──
        let tx = Arc::new(on_receive_tx);
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

                        if let Ok(text) = String::from_utf8(buf) {
                            if !text.is_empty() {
                                let _ = tx.send(text);
                            }
                        }
                    }

                    request.Respond()?;
                    deferral.Complete()?;
                }
                Ok(())
            },
        ))?;

        // ── 开始广播 ──
        let adv_params = GattServiceProviderAdvertisingParameters::new()?;
        adv_params.SetIsDiscoverable(true)?;
        adv_params.SetIsConnectable(true)?;

        if let Err(e) = provider.StartAdvertisingWithParameters(&adv_params) {
            println!("[BLE] 带参数广播失败 ({:?}), 尝试默认广播...", e);
            provider
                .StartAdvertising()
                .context("启动 BLE 广播失败")?;
        } else {
            println!("[BLE] ✅ 已启动可发现 & 可连接的 GATT 广播");
        }

        log::info!(
            "[BLE] GATT Server 已启动并广播中 (Service: {:?})",
            SERVICE_UUID
        );

        Ok(Self {
            _provider: provider,
            notify_char,
        })
    }

    /// 向所有订阅者发送剪贴板内容 (阻塞调用)
    ///
    /// 返回实际通知的设备数量
    pub fn notify_clipboard(&self, text: &str) -> Result<u32> {
        let subscribers = self.notify_char.SubscribedClients()?;
        let count = subscribers.Size()?;

        if count == 0 {
            return Ok(0);
        }

        // 文本长度检查 (第一版限制 16KB)
        let bytes = text.as_bytes();
        if bytes.len() > 16 * 1024 {
            anyhow::bail!("文本过大 ({} 字节), 第一版限制 16KB", bytes.len());
        }

        let writer = DataWriter::new()?;
        writer.WriteBytes(bytes)?;
        let buffer = writer.DetachBuffer()?;

        self.notify_char
            .NotifyValueAsync(&buffer)?
            .get()
            .context("BLE Notify 发送失败")?;

        Ok(count)
    }
}
