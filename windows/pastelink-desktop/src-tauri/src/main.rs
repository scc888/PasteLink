// Prevents console window on Windows across all build configurations, DO NOT REMOVE!!
#![windows_subsystem = "windows"]

fn main() {
    std::panic::set_hook(Box::new(|info| {
        let payload = if let Some(s) = info.payload().downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "Unknown panic payload".to_string()
        };
        let location = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "unknown location".to_string());
        let msg = format!("PANIC at {}: {}\nDetails: {:?}", location, payload, info);
        if let Ok(appdata) = std::env::var("APPDATA") {
            let log_dir = std::path::PathBuf::from(appdata).join("PasteLink");
            let _ = std::fs::create_dir_all(&log_dir);
            let _ = std::fs::write(log_dir.join("panic.log"), &msg);
        }
        let _ = std::fs::write("panic.log", &msg);
    }));
    pastelink_desktop_lib::run()
}
