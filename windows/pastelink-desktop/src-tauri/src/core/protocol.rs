use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

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
    pub item_type: String, // "url" | "code" | "otp" | "text"
    pub is_pinned: bool,
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
        }
    }
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

/// 计算文本的 SHA-256 哈希值用于去重
pub fn calculate_sha256(text: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    format!("{:x}", hasher.finalize())
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

// ─── BLE 分片传输协议 (64KB 长文本安全保障) ───────────────────

pub const CHUNK_MAGIC: &[u8; 4] = b"PLKC";
pub const MAX_CHUNK_PAYLOAD: usize = 480;

/// 将任意大小的密文载荷切片为符合 BLE MTU 的安全分片包
///
/// 分片包头格式: `[PLKC (4B)] + [msg_id (1B)] + [total_chunks (1B)] + [chunk_index (1B)] + [flags (1B)] + [payload (<=480B)]`
pub fn fragment_payload(data: &[u8], msg_id: u8) -> Vec<Vec<u8>> {
    if data.is_empty() {
        return Vec::new();
    }
    let total_chunks = ((data.len() + MAX_CHUNK_PAYLOAD - 1) / MAX_CHUNK_PAYLOAD) as u8;
    let mut chunks = Vec::with_capacity(total_chunks as usize);

    for (i, chunk_slice) in data.chunks(MAX_CHUNK_PAYLOAD).enumerate() {
        let mut packet = Vec::with_capacity(8 + chunk_slice.len());
        packet.extend_from_slice(CHUNK_MAGIC);
        packet.push(msg_id);
        packet.push(total_chunks);
        packet.push(i as u8);
        packet.push(0); // flags/reserved
        packet.extend_from_slice(chunk_slice);
        chunks.push(packet);
    }
    chunks
}

/// BLE 分片重组状态机
#[derive(Default)]
pub struct ChunkReassembler {
    current_msg_id: u8,
    total_chunks: u8,
    received_chunks: std::collections::HashMap<u8, Vec<u8>>,
    last_update: Option<std::time::Instant>,
}

impl ChunkReassembler {
    pub fn new() -> Self {
        Self::default()
    }

    /// 处理收到的分片。当所有分片接收完毕时返回完整 Payload，否则返回 None
    pub fn process_packet(&mut self, packet: &[u8]) -> Option<Vec<u8>> {
        // 兼容单包非切片模式 (如旧版本 PLK1 密文或明文)
        if packet.len() < 8 || &packet[0..4] != CHUNK_MAGIC {
            return Some(packet.to_vec());
        }

        let msg_id = packet[4];
        let total_chunks = packet[5];
        let chunk_index = packet[6];
        let payload = &packet[8..];

        let now = std::time::Instant::now();
        // 超过 4 秒超时或消息 ID 发生切换，丢弃之前未完成的陈旧分片
        if let Some(last) = self.last_update {
            if now.duration_since(last).as_secs() > 4 || msg_id != self.current_msg_id {
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
}



