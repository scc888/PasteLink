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
    ///
    /// 封装结构: `[PLK1 (4B)] + [Nonce (12B)] + [密文 + Tag (NB)]`
    pub fn encrypt(text: &str, key: &[u8; 32]) -> Result<Vec<u8>, String> {
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
        use aes_gcm::aead::rand_core::RngCore;
        let mut nonce_bytes = [0u8; 12];
        OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = cipher
            .encrypt(nonce, text.as_bytes())
            .map_err(|e| format!("AES-256-GCM 加密失败: {}", e))?;

        let mut packet = Vec::with_capacity(4 + 12 + ciphertext.len());
        packet.extend_from_slice(MAGIC_HEADER);
        packet.extend_from_slice(&nonce_bytes);
        packet.extend_from_slice(&ciphertext);

        Ok(packet)
    }

    /// 解密数据 (若为明文则平滑降级解码)
    pub fn decrypt(data: &[u8], key: &[u8; 32]) -> Result<String, String> {
        // 1. 检查是否携带 PLK1 加密封包头
        if data.len() >= 16 + 4 && &data[0..4] == MAGIC_HEADER {
            let nonce_bytes = &data[4..16];
            let ciphertext = &data[16..];

            let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
            let nonce = Nonce::from_slice(nonce_bytes);

            let plaintext = cipher
                .decrypt(nonce, ciphertext)
                .map_err(|e| format!("AES-256-GCM 解密失败 (可能配对码不匹配): {}", e))?;

            String::from_utf8(plaintext).map_err(|e| format!("UTF-8 解码失败: {}", e))
        } else {
            // 2. 兼容明文降级
            String::from_utf8(data.to_vec()).map_err(|e| format!("UTF-8 明文解析失败: {}", e))
        }
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
}
