//! Windows 开机自启动注册表管理
use std::env;
use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_WRITE};
use winreg::RegKey;

const APP_NAME: &str = "PasteLink";
const RUN_KEY_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

pub struct AutoStartManager;

impl AutoStartManager {
    /// 检查是否已配置开机自启动
    pub fn is_enabled() -> bool {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        if let Ok(run_key) = hkcu.open_subkey_with_flags(RUN_KEY_PATH, KEY_READ) {
            let val: Result<String, _> = run_key.get_value(APP_NAME);
            val.is_ok()
        } else {
            false
        }
    }

    /// 设置开机自启动状态
    pub fn set_enabled(enabled: bool) -> Result<(), String> {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let (run_key, _) = hkcu
            .create_subkey_with_flags(RUN_KEY_PATH, KEY_WRITE)
            .map_err(|e| format!("无法访问启动注册表项: {}", e))?;

        if enabled {
            let current_exe = env::current_exe()
                .map_err(|e| format!("无法获取当前程序路径: {}", e))?
                .to_string_lossy()
                .to_string();

            let cmd = Self::format_cmd(&current_exe);
            run_key
                .set_value(APP_NAME, &cmd)
                .map_err(|e| format!("注册开机启动失败: {}", e))?;
            log::info!("[AutoStart] 已开启开机自启: {}", cmd);
        } else {
            let _ = run_key.delete_value(APP_NAME);
            log::info!("[AutoStart] 已关闭开机自启");
        }

        Ok(())
    }

    /// 格式化开机启动命令行
    pub fn format_cmd(exe_path: &str) -> String {
        format!("\"{}\" --minimized", exe_path)
    }

    /// 若用户此前已开启自启动，校验并自动同步为当前可执行文件路径（防止因路径迁移或调试版残留导致启动错误）
    pub fn sync_current_exe_if_enabled() {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        if let Ok(run_key) = hkcu.open_subkey_with_flags(RUN_KEY_PATH, KEY_READ | KEY_WRITE) {
            let val: Result<String, _> = run_key.get_value(APP_NAME);
            if let Ok(existing_cmd) = val {
                if let Ok(current_exe) = env::current_exe() {
                    let current_str = current_exe.to_string_lossy();
                    let expected_cmd = Self::format_cmd(&current_str);
                    if existing_cmd != expected_cmd {
                        let _ = run_key.set_value(APP_NAME, &expected_cmd);
                        log::info!(
                            "[AutoStart] 自动同步开机启动路径: 原路径 [{}], 新路径 [{}]",
                            existing_cmd,
                            expected_cmd
                        );
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_cmd() {
        let exe = r"C:\Program Files\PasteLink\PasteLink.exe";
        let cmd = AutoStartManager::format_cmd(exe);
        assert_eq!(cmd, r#""C:\Program Files\PasteLink\PasteLink.exe" --minimized"#);
    }
}
