use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// 跨模块剪贴板传输载荷类型
#[derive(Debug, Clone)]
pub enum ClipboardPayload {
    Text(String),
    Image {
        width: u32,
        height: u32,
        png_bytes: Vec<u8>,
    },
}

/// 剪贴板条目数据结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: String,
    pub content: String,
    pub source: String, // "windows" | "iphone"
    pub timestamp: i64,
    pub sha256: String,
    pub preview: String,
    pub char_count: usize,
    pub item_type: String, // "url" | "code" | "otp" | "text" | "image"
    pub is_pinned: bool,
    #[serde(default)]
    pub image_data: Option<String>,
    #[serde(default)]
    pub width: Option<u32>,
    #[serde(default)]
    pub height: Option<u32>,
    #[serde(default)]
    pub file_size: Option<usize>,
}

impl ClipboardItem {
    pub fn new(content: String, source: &str) -> Self {
        let sha256 = calculate_sha256(&content);
        let preview = make_preview(&content, 80);
        let timestamp = chrono::Utc::now().timestamp_millis();
        let id = Uuid::new_v4().to_string();
        let char_count = content.chars().count();
        let item_type = detect_item_type(&content).to_string();

        Self {
            id,
            content,
            source: source.to_string(),
            timestamp,
            sha256,
            preview,
            char_count,
            item_type,
            is_pinned: false,
            image_data: None,
            width: None,
            height: None,
            file_size: None,
        }
    }

    pub fn new_image(png_bytes: &[u8], width: u32, height: u32, source: &str) -> Self {
        let sha256 = calculate_sha256_bytes(png_bytes);
        let file_size = png_bytes.len();
        let preview = format!("图像 ({} × {}, {})", width, height, format_bytes(file_size));
        let timestamp = chrono::Utc::now().timestamp_millis();
        let id = Uuid::new_v4().to_string();
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(png_bytes);
        let image_data = Some(format!("data:image/png;base64,{}", b64));

        Self {
            id,
            content: format!("[图片: {}×{}, {}]", width, height, format_bytes(file_size)),
            source: source.to_string(),
            timestamp,
            sha256,
            preview,
            char_count: 0,
            item_type: "image".to_string(),
            is_pinned: false,
            image_data,
            width: Some(width),
            height: Some(height),
            file_size: Some(file_size),
        }
    }
}

/// 格式化字节数大小
pub fn format_bytes(bytes: usize) -> String {
    if bytes < 1024 {
        format!("{} B", bytes)
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.2} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}

/// 计算二进制数据的 SHA-256 哈希值用于去重
pub fn calculate_sha256_bytes(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    format!("{:x}", hasher.finalize())
}

/// 智能识别剪贴板数据类型
pub fn detect_item_type(text: &str) -> &'static str {
    let trimmed = text.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return "url";
    }
    // 4~8 位纯数字验证码
    if trimmed.len() >= 4 && trimmed.len() <= 8 && trimmed.chars().all(|c| c.is_ascii_digit()) {
        return "otp";
    }
    // 代码/JSON特征
    if (trimmed.starts_with('{') && trimmed.ends_with('}'))
        || (trimmed.starts_with('[') && trimmed.ends_with(']'))
        || trimmed.starts_with("function ")
        || trimmed.starts_with("const ")
        || trimmed.starts_with("let ")
        || trimmed.starts_with("var ")
        || trimmed.starts_with("def ")
        || trimmed.starts_with("import ")
        || trimmed.starts_with("curl ")
        || trimmed.contains(";\n")
        || (trimmed.contains('\n') && (trimmed.contains("    ") || trimmed.contains('\t')))
    {
        return "code";
    }
    "text"
}

/// 计算文本的 SHA-256 哈希值用于去重 (统一将 \r\n 标准化为 \n，消除跨系统差异)
pub fn calculate_sha256(text: &str) -> String {
    let normalized = text.replace("\r\n", "\n");
    calculate_sha256_bytes(normalized.as_bytes())
}

/// 生成安全预览文本
pub fn make_preview(text: &str, max_chars: usize) -> String {
    let single_line = text.replace('\r', "").replace('\n', " ↵ ");
    let char_count = single_line.chars().count();
    if char_count > max_chars {
        let truncated: String = single_line.chars().take(max_chars).collect();
        format!("{}...", truncated)
    } else {
        single_line
    }
}

// ─── 图像编码与解码模块 (100% 像素级无损 PNG) ───────────────────

pub const IMAGE_MAGIC: &[u8; 4] = b"PLKI"; // PasteLink Image Binary Header

/// 将 RAW RGBA 位图编码为 100% 像素级无损 PNG
pub fn encode_rgba_to_png(width: u32, height: u32, rgba: &[u8]) -> Result<Vec<u8>, String> {
    let expected_len = (width as usize) * (height as usize) * 4;
    if rgba.len() != expected_len {
        return Err(format!(
            "RGBA 缓冲区大小不匹配: 期望 {} 字节, 实际 {} 字节",
            expected_len,
            rgba.len()
        ));
    }

    let img_buffer: image::RgbaImage = image::ImageBuffer::from_raw(width, height, rgba.to_vec())
        .ok_or_else(|| "构建 ImageBuffer 失败".to_string())?;

    let mut png_bytes = Vec::new();
    img_buffer
        .write_to(&mut std::io::Cursor::new(&mut png_bytes), image::ImageFormat::Png)
        .map_err(|e| format!("PNG 编码失败: {}", e))?;

    Ok(png_bytes)
}

/// 将 PNG 字节流解码为 RAW RGBA 位图 (供写入系统剪贴板)
pub fn decode_png_to_rgba(png_bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    let img = image::load_from_memory_with_format(png_bytes, image::ImageFormat::Png)
        .map_err(|e| format!("PNG 解码失败: {}", e))?;

    let rgba_img = img.to_rgba8();
    let width = rgba_img.width();
    let height = rgba_img.height();
    let bytes = rgba_img.into_raw();

    Ok((width, height, bytes))
}

/// 封装图像二进制传输载荷
///
/// 封装结构: `[PLKI (4B)] + [width (4B be)] + [height (4B be)] + [png_bytes (NB)]`
pub fn wrap_image_payload(png_bytes: &[u8], width: u32, height: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(12 + png_bytes.len());
    payload.extend_from_slice(IMAGE_MAGIC);
    payload.extend_from_slice(&width.to_be_bytes());
    payload.extend_from_slice(&height.to_be_bytes());
    payload.extend_from_slice(png_bytes);
    payload
}

/// 解包图像二进制传输载荷
pub fn unwrap_image_payload(payload: &[u8]) -> Option<(u32, u32, &[u8])> {
    if payload.len() >= 12 && &payload[0..4] == IMAGE_MAGIC {
        let width = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);
        let height = u32::from_be_bytes([payload[8], payload[9], payload[10], payload[11]]);
        let png_bytes = &payload[12..];
        Some((width, height, png_bytes))
    } else {
        None
    }
}

// ─── BLE 分片传输协议 (u16 宽索引，支持高达 30MB 载荷传输) ────

pub const CHUNK_MAGIC: &[u8; 4] = b"PLKC";
pub const MAX_CHUNK_PAYLOAD: usize = 480;

/// 将任意大小的密文载荷切片为符合 BLE MTU 的安全分片包
///
/// 分片包头格式: `[PLKC (4B)] + [msg_id (1B)] + [total_chunks (2B be)] + [chunk_index (2B be)] + [flags (1B)] + [payload (<=480B)]` (共 10 字节)
pub fn fragment_payload(data: &[u8], msg_id: u8) -> Vec<Vec<u8>> {
    if data.is_empty() {
        return Vec::new();
    }
    let total_chunks = ((data.len() + MAX_CHUNK_PAYLOAD - 1) / MAX_CHUNK_PAYLOAD) as u16;
    let mut chunks = Vec::with_capacity(total_chunks as usize);

    for (i, chunk_slice) in data.chunks(MAX_CHUNK_PAYLOAD).enumerate() {
        let mut packet = Vec::with_capacity(10 + chunk_slice.len());
        packet.extend_from_slice(CHUNK_MAGIC);
        packet.push(msg_id);
        packet.extend_from_slice(&total_chunks.to_be_bytes());
        packet.extend_from_slice(&(i as u16).to_be_bytes());
        packet.push(0); // flags/reserved
        packet.extend_from_slice(chunk_slice);
        chunks.push(packet);
    }
    chunks
}

/// BLE 分片重组状态机 (支持 u16 宽索引与长周期超时)
#[derive(Default)]
pub struct ChunkReassembler {
    current_msg_id: u8,
    total_chunks: u16,
    received_chunks: std::collections::HashMap<u16, Vec<u8>>,
    last_update: Option<std::time::Instant>,
}

impl ChunkReassembler {
    pub fn new() -> Self {
        Self::default()
    }

    /// 处理收到的分片。当所有分片接收完毕时返回完整 Payload，否则返回 None
    pub fn process_packet(&mut self, packet: &[u8]) -> Option<Vec<u8>> {
        // 兼容单包非切片模式 (如旧版本 PLK1 密文或明文)
        if packet.len() < 10 || &packet[0..4] != CHUNK_MAGIC {
            return Some(packet.to_vec());
        }

        let msg_id = packet[4];
        let total_chunks = u16::from_be_bytes([packet[5], packet[6]]);
        let chunk_index = u16::from_be_bytes([packet[7], packet[8]]);
        let payload = &packet[10..];

        let now = std::time::Instant::now();
        // 超过 90 秒超时 (保障大文件/原图平稳传输) 或消息 ID 发生切换，丢弃未完成的陈旧分片
        if let Some(last) = self.last_update {
            if now.duration_since(last).as_secs() > 90 || msg_id != self.current_msg_id {
                self.received_chunks.clear();
            }
        }

        self.current_msg_id = msg_id;
        self.total_chunks = total_chunks;
        self.last_update = Some(now);
        self.received_chunks.insert(chunk_index, payload.to_vec());

        // 检查所有分片是否已经集齐
        if self.received_chunks.len() == total_chunks as usize {
            let mut full_payload = Vec::new();
            for i in 0..total_chunks {
                if let Some(chunk_data) = self.received_chunks.get(&i) {
                    full_payload.extend_from_slice(chunk_data);
                } else {
                    return None;
                }
            }
            self.received_chunks.clear();
            self.last_update = None;
            Some(full_payload)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_item_type() {
        assert_eq!(detect_item_type("https://github.com"), "url");
        assert_eq!(detect_item_type("http://192.168.1.1:8080"), "url");
        assert_eq!(detect_item_type("839201"), "otp");
        assert_eq!(detect_item_type("{\"name\": \"pastelink\"}"), "code");
        assert_eq!(detect_item_type("const a = 123;"), "code");
        assert_eq!(detect_item_type("Hello World! This is a test."), "text");
    }

    #[test]
    fn test_sha256_calculation() {
        let h1 = calculate_sha256("test content");
        let h2 = calculate_sha256("test content");
        let h3 = calculate_sha256("other content");
        assert_eq!(h1, h2);
        assert_ne!(h1, h3);
    }

    #[test]
    fn test_make_preview() {
        let text = "Line 1\nLine 2\r\nLine 3";
        let preview = make_preview(text, 50);
        assert_eq!(preview, "Line 1 ↵ Line 2 ↵ Line 3");
    }

    #[test]
    fn test_ble_fragmentation_roundtrip() {
        // 测试 2500 字节数据（需切片为 6 个分片包）
        let raw_data = vec![0xAB; 2500];
        let msg_id = 42;
        let packets = fragment_payload(&raw_data, msg_id);
        assert_eq!(packets.len(), 6);

        let mut reassembler = ChunkReassembler::new();
        let mut reassembled = None;

        for (idx, packet) in packets.iter().enumerate() {
            let res = reassembler.process_packet(packet);
            if idx < 5 {
                assert!(res.is_none(), "在集齐前不应返回完整数据");
            } else {
                reassembled = res;
            }
        }

        assert_eq!(reassembled, Some(raw_data));
    }

    #[test]
    fn test_ble_fragmentation_single_chunk() {
        let raw_data = b"small payload".to_vec();
        let packets = fragment_payload(&raw_data, 1);
        assert_eq!(packets.len(), 1);

        let mut reassembler = ChunkReassembler::new();
        let result = reassembler.process_packet(&packets[0]);
        assert_eq!(result, Some(raw_data));
    }

    #[test]
    fn test_png_encoding_decoding_roundtrip() {
        // 创建一个 4x4 的 RGBA 图像测试数据 (64 字节)
        let width = 4;
        let height = 4;
        let mut raw_rgba = Vec::with_capacity((width * height * 4) as usize);
        for i in 0..(width * height) {
            raw_rgba.push((i * 10) as u8); // R
            raw_rgba.push((i * 15) as u8); // G
            raw_rgba.push((i * 20) as u8); // B
            raw_rgba.push(255);            // A
        }

        let png_bytes = encode_rgba_to_png(width, height, &raw_rgba).expect("PNG 编码失败");
        assert!(!png_bytes.is_empty());
        assert_eq!(&png_bytes[1..4], b"PNG");

        let (dec_w, dec_h, dec_rgba) = decode_png_to_rgba(&png_bytes).expect("PNG 解码失败");
        assert_eq!(dec_w, width);
        assert_eq!(dec_h, height);
        assert_eq!(dec_rgba, raw_rgba);
    }

    #[test]
    fn test_image_payload_wrap_unwrap() {
        let dummy_png = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        let width = 1920;
        let height = 1080;
        let payload = wrap_image_payload(&dummy_png, width, height);
        assert_eq!(&payload[0..4], IMAGE_MAGIC);

        let unwrapped = unwrap_image_payload(&payload).expect("解包失败");
        assert_eq!(unwrapped.0, width);
        assert_eq!(unwrapped.1, height);
        assert_eq!(unwrapped.2, &dummy_png[..]);
    }

    #[test]
    fn test_large_u16_fragmentation_roundtrip() {
        // 测试 120,000 字节大数据 (250 个分片，验证突破旧版 255 限制与 u16 稳定性)
        let large_data = vec![0x5A; 120_000];
        let msg_id = 99;
        let packets = fragment_payload(&large_data, msg_id);
        assert_eq!(packets.len(), 250);

        let mut reassembler = ChunkReassembler::new();
        let mut reassembled = None;

        for (idx, packet) in packets.iter().enumerate() {
            let res = reassembler.process_packet(packet);
            if idx < 249 {
                assert!(res.is_none());
            } else {
                reassembled = res;
            }
        }

        assert_eq!(reassembled, Some(large_data));
    }
}



