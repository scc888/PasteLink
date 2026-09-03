use crate::core::protocol::ClipboardItem;
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::Sender;

const MAX_HISTORY: usize = 30;
const MAX_DEDUP_HASHES: usize = 50;

#[derive(Clone)]
pub struct AppState {
    pub is_paused: Arc<AtomicBool>,
    pub ignore_password_manager: Arc<AtomicBool>,
    pub connected_devices_count: Arc<AtomicU32>,
    pub recent_items: Arc<Mutex<VecDeque<ClipboardItem>>>,
    pub pairing_code: Arc<Mutex<String>>,
    pub dedup_hashes: Arc<Mutex<VecDeque<String>>>,
    pub clip_send_tx: Sender<String>,
}

#[derive(Serialize)]
pub struct StatusPayload {
    pub is_paused: bool,
    pub ignore_password_manager: bool,
    pub autostart_enabled: bool,
    pub connected_devices: u32,
    pub pairing_code: String,
    pub recent_items: Vec<ClipboardItem>,
}

impl AppState {
    pub fn new(clip_send_tx: Sender<String>) -> Self {
        Self {
            is_paused: Arc::new(AtomicBool::new(false)),
            ignore_password_manager: Arc::new(AtomicBool::new(true)),
            connected_devices_count: Arc::new(AtomicU32::new(0)),
            recent_items: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_HISTORY))),
            pairing_code: Arc::new(Mutex::new(Self::generate_pin())),
            dedup_hashes: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_DEDUP_HASHES))),
            clip_send_tx,
        }
    }

    pub fn generate_pin() -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(123456);
        let num = 100_000 + (seed % 900_000);
        let s = num.to_string();
        format!("{} {}", &s[0..3], &s[3..6])
    }

    pub fn is_paused(&self) -> bool {
        self.is_paused.load(Ordering::SeqCst)
    }

    pub fn set_paused(&self, paused: bool) {
        self.is_paused.store(paused, Ordering::SeqCst);
    }

    pub fn set_connected_devices(&self, count: u32) {
        self.connected_devices_count.store(count, Ordering::SeqCst);
    }

    pub fn get_connected_devices(&self) -> u32 {
        self.connected_devices_count.load(Ordering::SeqCst)
    }

    /// 检查哈希是否已存在（去重与防回环）
    pub fn is_duplicate_or_record(&self, sha256: &str) -> bool {
        let mut hashes = self.dedup_hashes.lock().unwrap();
        if hashes.contains(&sha256.to_string()) {
            return true;
        }
        if hashes.len() >= MAX_DEDUP_HASHES {
            hashes.pop_front();
        }
        hashes.push_back(sha256.to_string());
        false
    }

    /// 添加一条剪贴板记录
    pub fn add_item(&self, item: ClipboardItem) {
        let mut items = self.recent_items.lock().unwrap();
        // 移除相同 hash 的旧项（提升至顶部）
        items.retain(|i| i.sha256 != item.sha256);
        if items.len() >= MAX_HISTORY {
            items.pop_back();
        }
        items.push_front(item);
    }

    pub fn delete_item(&self, id: &str) {
        let mut items = self.recent_items.lock().unwrap();
        items.retain(|i| i.id != id);
    }

    pub fn toggle_pin_item(&self, id: &str) -> bool {
        let mut items = self.recent_items.lock().unwrap();
        let mut is_pinned = false;
        for item in items.iter_mut() {
            if item.id == id {
                item.is_pinned = !item.is_pinned;
                is_pinned = item.is_pinned;
                break;
            }
        }
        is_pinned
    }

    pub fn clear_history(&self) {
        let mut items = self.recent_items.lock().unwrap();
        // 保留已置顶/收藏的项目
        items.retain(|i| i.is_pinned);
    }

    pub fn should_ignore_password_manager(&self) -> bool {
        self.ignore_password_manager.load(Ordering::SeqCst)
    }

    pub fn set_ignore_password_manager(&self, ignore: bool) {
        self.ignore_password_manager.store(ignore, Ordering::SeqCst);
    }

    pub fn get_status_payload(&self) -> StatusPayload {
        let items: Vec<ClipboardItem> = self.recent_items.lock().unwrap().iter().cloned().collect();
        let code = self.pairing_code.lock().unwrap().clone();
        let autostart_enabled = crate::core::autostart::AutoStartManager::is_enabled();

        StatusPayload {
            is_paused: self.is_paused(),
            ignore_password_manager: self.should_ignore_password_manager(),
            autostart_enabled,
            connected_devices: self.get_connected_devices(),
            pairing_code: code,
            recent_items: items,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_app_state_operations() {
        let (tx, _rx) = tokio::sync::mpsc::channel(10);
        let state = AppState::new(tx);

        let item1 = ClipboardItem::new("item 1".to_string(), "windows");
        let item2 = ClipboardItem::new("item 2".to_string(), "iphone");

        state.add_item(item1.clone());
        state.add_item(item2.clone());

        assert_eq!(state.recent_items.lock().unwrap().len(), 2);

        // Test pin
        let is_pinned = state.toggle_pin_item(&item1.id);
        assert!(is_pinned);

        // Test clear history retains pinned
        state.clear_history();
        assert_eq!(state.recent_items.lock().unwrap().len(), 1);
        assert_eq!(state.recent_items.lock().unwrap()[0].id, item1.id);

        // Test delete item
        state.delete_item(&item1.id);
        assert_eq!(state.recent_items.lock().unwrap().len(), 0);
    }
}

