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
}


