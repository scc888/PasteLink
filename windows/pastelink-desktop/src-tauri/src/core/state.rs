use crate::core::protocol::{ClipboardItem, ClipboardPayload};
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc::Sender;

use std::path::PathBuf;

const MAX_HISTORY: usize = 30;
const MAX_DEDUP_HASHES: usize = 50;
const LAN_HEARTBEAT_TTL: Duration = Duration::from_secs(25);

#[derive(serde::Serialize, serde::Deserialize, Default, Clone)]
pub struct PersistentSettings {
    pub pairing_code: Option<String>,
    pub ignore_password_manager: Option<bool>,
}

impl PersistentSettings {
    fn config_path() -> Option<PathBuf> {
        if let Ok(appdata) = std::env::var("APPDATA") {
            let mut path = PathBuf::from(appdata);
            path.push("PasteLink");
            let _ = std::fs::create_dir_all(&path);
            path.push("settings.json");
            return Some(path);
        }
        None
    }

    pub fn load() -> Self {
        if let Some(path) = Self::config_path() {
            if path.exists() {
                if let Ok(content) = std::fs::read_to_string(&path) {
                    if let Ok(settings) = serde_json::from_str::<Self>(&content) {
                        return settings;
                    }
                }
            }
        }
        Self::default()
    }

    pub fn save(&self) {
        if let Some(path) = Self::config_path() {
            if let Ok(json) = serde_json::to_string_pretty(self) {
                let _ = std::fs::write(path, json);
            }
        }
    }
}

#[derive(Clone)]
pub struct AppState {
    pub is_paused: Arc<AtomicBool>,
    pub ignore_password_manager: Arc<AtomicBool>,
    pub connected_devices_count: Arc<AtomicU32>,
    pub lan_last_seen: Arc<Mutex<Option<Instant>>>,
    pub recent_items: Arc<Mutex<VecDeque<ClipboardItem>>>,
    pub pairing_code: Arc<Mutex<String>>,
    pub dedup_hashes: Arc<Mutex<VecDeque<String>>>,
    pub clip_send_tx: Sender<ClipboardPayload>,
    pub latest_payload: Arc<Mutex<Option<Vec<u8>>>>,
    pub payload_lan_fetched: Arc<AtomicBool>,
}

#[derive(Serialize)]
pub struct StatusPayload {
    pub is_paused: bool,
    pub ignore_password_manager: bool,
    pub autostart_enabled: bool,
    pub connected_devices: u32,
    pub lan_connected: bool,
    pub pairing_code: String,
    pub recent_items: Vec<ClipboardItem>,
}

impl AppState {
    pub fn new(clip_send_tx: Sender<ClipboardPayload>) -> Self {
        let settings = PersistentSettings::load();
        let (initial_pin, save_needed) = if let Some(code) = settings.pairing_code {
            let clean = code.replace(' ', "");
            if clean.len() == 6 && clean.chars().all(|c| c.is_ascii_digit()) {
                (code, false)
            } else {
                (Self::generate_pin(), true)
            }
        } else {
            (Self::generate_pin(), true)
        };

        let ignore_pwd = settings.ignore_password_manager.unwrap_or(true);

        let state = Self {
            is_paused: Arc::new(AtomicBool::new(false)),
            ignore_password_manager: Arc::new(AtomicBool::new(ignore_pwd)),
            connected_devices_count: Arc::new(AtomicU32::new(0)),
            lan_last_seen: Arc::new(Mutex::new(None)),
            recent_items: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_HISTORY))),
            pairing_code: Arc::new(Mutex::new(initial_pin.clone())),
            dedup_hashes: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_DEDUP_HASHES))),
            clip_send_tx,
            latest_payload: Arc::new(Mutex::new(None)),
            payload_lan_fetched: Arc::new(AtomicBool::new(false)),
        };

        if save_needed {
            state.persist_current_settings();
        }

        state
    }

    pub fn set_latest_payload(&self, payload: Vec<u8>) {
        let mut p = self.latest_payload.lock().unwrap();
        *p = Some(payload);
        self.payload_lan_fetched.store(false, Ordering::Relaxed);
    }

    pub fn get_latest_payload(&self) -> Option<Vec<u8>> {
        let p = self.latest_payload.lock().unwrap();
        p.clone()
    }

    pub fn mark_payload_fetched_over_lan(&self) {
        self.payload_lan_fetched.store(true, Ordering::Relaxed);
    }

    pub fn is_payload_fetched_over_lan(&self) -> bool {
        self.payload_lan_fetched.load(Ordering::Relaxed)
    }

    pub fn persist_current_settings(&self) {
        let code = self.pairing_code.lock().unwrap().clone();
        let ignore = self.should_ignore_password_manager();
        let settings = PersistentSettings {
            pairing_code: Some(code),
            ignore_password_manager: Some(ignore),
        };
        settings.save();
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

    pub fn mark_lan_seen(&self) {
        *self.lan_last_seen.lock().unwrap() = Some(Instant::now());
    }

    pub fn clear_lan_seen(&self) {
        *self.lan_last_seen.lock().unwrap() = None;
    }

    pub fn is_lan_connected(&self) -> bool {
        self.lan_last_seen.lock().unwrap()
            .map(|last| last.elapsed() < LAN_HEARTBEAT_TTL)
            .unwrap_or(false)
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
    pub fn add_item(&self, mut item: ClipboardItem) {
        let mut items = self.recent_items.lock().unwrap();
        item.is_pinned |= items.iter().any(|i| i.sha256 == item.sha256 && i.is_pinned);
        items.retain(|i| i.sha256 != item.sha256);
        items.push_front(item);
        Self::trim_unpinned_history(&mut items);
    }

    fn trim_unpinned_history(items: &mut VecDeque<ClipboardItem>) {
        let mut unpinned_count = 0;
        items.retain(|item| {
            if item.is_pinned {
                return true;
            }
            unpinned_count += 1;
            unpinned_count <= MAX_HISTORY
        });
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
        Self::trim_unpinned_history(&mut items);
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
        self.persist_current_settings();
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
            lan_connected: self.is_lan_connected(),
            pairing_code: code,
            recent_items: items,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_state() -> AppState {
        let (tx, _rx) = tokio::sync::mpsc::channel(1);
        AppState::new(tx)
    }

    #[test]
    fn history_capacity_never_evicts_pinned_items() {
        let state = test_state();
        let pinned = ClipboardItem::new("keep this".into(), "windows");
        state.add_item(pinned.clone());
        state.toggle_pin_item(&pinned.id);
        for i in 0..MAX_HISTORY + 5 {
            state.add_item(ClipboardItem::new(format!("entry {i}"), "windows"));
        }
        let items = state.recent_items.lock().unwrap();
        assert!(items.iter().any(|i| i.id == pinned.id && i.is_pinned));
        assert_eq!(items.iter().filter(|i| !i.is_pinned).count(), MAX_HISTORY);
        assert!(!items.iter().any(|i| i.content == "entry 0"));
    }

    #[test]
    fn repeated_content_preserves_its_pin_and_updates_the_entry() {
        let state = test_state();
        let original = ClipboardItem::new("same content".into(), "windows");
        state.add_item(original.clone());
        state.toggle_pin_item(&original.id);
        let repeat = ClipboardItem::new("same content".into(), "iphone");
        state.add_item(repeat.clone());
        let items = state.recent_items.lock().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, repeat.id);
        assert_eq!(items[0].source, "iphone");
        assert!(items[0].is_pinned);
    }

    #[test]
    fn all_pinned_history_still_accepts_a_new_unpinned_entry() {
        let state = test_state();
        for i in 0..MAX_HISTORY {
            let item = ClipboardItem::new(format!("pinned {i}"), "windows");
            state.add_item(item.clone());
            state.toggle_pin_item(&item.id);
        }
        state.add_item(ClipboardItem::new("new".into(), "iphone"));
        let items = state.recent_items.lock().unwrap();
        assert_eq!(items.iter().filter(|i| i.is_pinned).count(), MAX_HISTORY);
        assert_eq!(items[0].content, "new");
    }

    #[test]
    fn unpinning_reapplies_the_unpinned_history_limit() {
        let state = test_state();
        let oldest = ClipboardItem::new("old pin".into(), "windows");
        state.add_item(oldest.clone());
        state.toggle_pin_item(&oldest.id);
        for i in 0..MAX_HISTORY {
            state.add_item(ClipboardItem::new(format!("new {i}"), "windows"));
        }
        assert!(state.recent_items.lock().unwrap().iter().any(|i| i.id == oldest.id && i.is_pinned));
        assert!(!state.toggle_pin_item(&oldest.id));
        let items = state.recent_items.lock().unwrap();
        assert_eq!(items.len(), MAX_HISTORY);
        assert!(!items.iter().any(|i| i.id == oldest.id));
    }

    #[test]
    fn status_reports_lan_unavailable_before_first_heartbeat() {
        let (tx, _rx) = tokio::sync::mpsc::channel(1);
        let state = AppState::new(tx);
        let status = serde_json::to_value(state.get_status_payload()).unwrap();
        assert_eq!(status.get("lan_connected"), Some(&serde_json::Value::Bool(false)));
    }

    #[test]
    fn lan_heartbeat_becomes_available_and_expires() {
        let (tx, _rx) = tokio::sync::mpsc::channel(1);
        let state = AppState::new(tx);
        state.mark_lan_seen();
        assert!(state.is_lan_connected());
        *state.lan_last_seen.lock().unwrap() = Some(Instant::now() - LAN_HEARTBEAT_TTL);
        assert!(!state.is_lan_connected());
        state.mark_lan_seen();
        state.clear_lan_seen();
        assert!(!state.is_lan_connected());
    }

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

