//! 端到端 AES-256-GCM 安全加密中枢
use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use sha2::{Digest, Sha256};

const MAGIC_HEADER: &[u8; 4] = b"PLK1"; // PasteLink v1 Encrypted Envelope
const SALT: &[u8] = b"PasteLink-ZeroTrust-Salt-v1";

pub struct CryptoEngine;

impl CryptoEngine {
    /// 从 6 位数字配对码生成 256 位对称密钥
    pub fn derive_key(pin: &str) -> [u8; 32] {
        let clean_pin = pin.replace(' ', "").trim().to_string();
        let mut hasher = Sha256::new();
        hasher.update(SALT);
        hasher.update(clean_pin.as_bytes());
        let result = hasher.finalize();
        let mut key = [0u8; 32];
        key.copy_from_slice(&result[..32]);
        key
    }

    /// 使用 AES-256-GCM 加密文本
    pub fn encrypt(text: &str, key: &[u8; 32]) -> Result<Vec<u8>, String> {
        Self::encrypt_raw(text.as_bytes(), key)
    }

    /// 使用 AES-256-GCM 加密任意原始二进制数据
    ///
    /// 封装结构: `[PLK1 (4B)] + [Nonce (12B)] + [密文 + Tag (NB)]`
    pub fn encrypt_raw(data: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, String> {
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
        use aes_gcm::aead::rand_core::RngCore;
        let mut nonce_bytes = [0u8; 12];
        OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = cipher
            .encrypt(nonce, data)
            .map_err(|e| format!("AES-256-GCM 加密失败: {}", e))?;

        let mut packet = Vec::with_capacity(4 + 12 + ciphertext.len());
        packet.extend_from_slice(MAGIC_HEADER);
        packet.extend_from_slice(&nonce_bytes);
        packet.extend_from_slice(&ciphertext);

        Ok(packet)
    }

    /// 解密原始二进制数据 (若为明文则平滑降级)
    pub fn decrypt_raw(data: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, String> {
        // 1. 检查是否携带 PLK1 加密封包头
        if data.len() >= 16 + 4 && &data[0..4] == MAGIC_HEADER {
            let nonce_bytes = &data[4..16];
            let ciphertext = &data[16..];

            let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
            let nonce = Nonce::from_slice(nonce_bytes);

            let plaintext = cipher
                .decrypt(nonce, ciphertext)
                .map_err(|e| format!("AES-256-GCM 解密失败 (可能配对码不匹配): {}", e))?;

            Ok(plaintext)
        } else {
            // 2. 兼容明文降级
            Ok(data.to_vec())
        }
    }

    /// 解密数据并解析为 UTF-8 文本
    pub fn decrypt(data: &[u8], key: &[u8; 32]) -> Result<String, String> {
        let raw = Self::decrypt_raw(data, key)?;
        String::from_utf8(raw).map_err(|e| format!("UTF-8 解码失败: {}", e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_crypto_derive_key() {
        let k1 = CryptoEngine::derive_key("482 915");
        let k2 = CryptoEngine::derive_key("482915");
        assert_eq!(k1, k2);
        assert_eq!(k1.len(), 32);
    }

    #[test]
    fn test_crypto_encrypt_decrypt_roundtrip() {
        let key = CryptoEngine::derive_key("123456");
        let plaintext = "https://github.com/pastelink/app - 跨设备剪贴板同步";
        let encrypted = CryptoEngine::encrypt(plaintext, &key).expect("加密失败");
        assert!(encrypted.len() > 16 + 4);
        assert_eq!(&encrypted[0..4], b"PLK1");

        let decrypted = CryptoEngine::decrypt(&encrypted, &key).expect("解密失败");
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_crypto_plaintext_fallback() {
        let key = CryptoEngine::derive_key("123456");
        let plain_bytes = b"Hello Plaintext";
        let decrypted = CryptoEngine::decrypt(plain_bytes, &key).expect("明文降级失败");
        assert_eq!(decrypted, "Hello Plaintext");
    }

    #[test]
    fn test_crypto_raw_binary_roundtrip() {
        let key = CryptoEngine::derive_key("123456");
        // 非法 UTF-8 二进制数据（如图片字节）
        let raw_binary = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x00, 0xC0];
        let encrypted = CryptoEngine::encrypt_raw(&raw_binary, &key).expect("二进制加密失败");
        assert_eq!(&encrypted[0..4], b"PLK1");

        let decrypted = CryptoEngine::decrypt_raw(&encrypted, &key).expect("二进制解密失败");
        assert_eq!(decrypted, raw_binary);
    }
}
