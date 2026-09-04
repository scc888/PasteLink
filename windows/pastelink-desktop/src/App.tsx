import { useEffect, useState, useMemo, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  Laptop,
  Smartphone,
  Trash2,
  RefreshCw,
  Pause,
  Play,
  X,
  ShieldCheck,
  ClipboardList,
  Settings as SettingsIcon,
  ArrowLeft,
  Search,
  Pin,
  ExternalLink,
  Copy,
  Check,
  Sparkles,
  Command,
  FileCode,
  Link2,
  KeyRound,
  FileText,
  Eye,
} from "lucide-react";
import { ClipboardItem, StatusPayload } from "./types";
import "./App.css";

export default function App() {
  const [status, setStatus] = useState<StatusPayload>({
    is_paused: false,
    ignore_password_manager: true,
    autostart_enabled: false,
    connected_devices: 0,
    pairing_code: "--- ---",
    recent_items: [],
  });

  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [toastMsg, setToastMsg] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [filterType, setFilterType] = useState<"all" | "windows" | "iphone" | "pinned">("all");
  const [selectedItem, setSelectedItem] = useState<ClipboardItem | null>(null);
  const [copiedPin, setCopiedPin] = useState(false);
  const [isRefreshingPin, setIsRefreshingPin] = useState(false);
  const [selectedIndex, setSelectedIndex] = useState<number>(0);

  const searchInputRef = useRef<HTMLInputElement>(null);

  const showToast = (msg: string) => {
    setToastMsg(msg);
    setTimeout(() => setToastMsg(null), 1800);
  };

  // 1. 初始化拉取状态并注册事件监听
  useEffect(() => {
    const fetchStatus = async () => {
      try {
        const data = await invoke<StatusPayload>("get_status");
        setStatus(data);
      } catch (e) {
        console.error("Failed to fetch initial status:", e);
      }
    };

    fetchStatus();

    // 订阅 Tauri 后端广播事件
    const unlistenSubscribers = listen<number>("ble-subscribers-changed", (event) => {
      setStatus((prev) => ({ ...prev, connected_devices: event.payload }));
    });

    const unlistenClipboard = listen<ClipboardItem>("clipboard-updated", (event) => {
      setStatus((prev) => {
        const filtered = prev.recent_items.filter((i) => i.sha256 !== event.payload.sha256);
        return {
          ...prev,
          recent_items: [event.payload, ...filtered].slice(0, 50),
        };
      });
    });

    const unlistenPause = listen<boolean>("pause-state-changed", (event) => {
      setStatus((prev) => ({ ...prev, is_paused: event.payload }));
    });

    const unlistenClear = listen("history-cleared", () => {
      setStatus((prev) => ({
        ...prev,
        recent_items: prev.recent_items.filter((i) => i.is_pinned),
      }));
    });

    const unlistenDeleted = listen<string>("history-item-deleted", (event) => {
      setStatus((prev) => ({
        ...prev,
        recent_items: prev.recent_items.filter((i) => i.id !== event.payload),
      }));
    });

    const unlistenPinned = listen<{ id: string; is_pinned: boolean }>(
      "history-item-pinned",
      (event) => {
        setStatus((prev) => ({
          ...prev,
          recent_items: prev.recent_items.map((i) =>
            i.id === event.payload.id ? { ...i, is_pinned: event.payload.is_pinned } : i
          ),
        }));
      }
    );

    const unlistenAutostart = listen<boolean>("autostart-changed", (event) => {
      setStatus((prev) => ({ ...prev, autostart_enabled: event.payload }));
    });

    const unlistenPasswordMgr = listen<boolean>("ignore-password-manager-changed", (event) => {
      setStatus((prev) => ({ ...prev, ignore_password_manager: event.payload }));
    });

    return () => {
      unlistenSubscribers.then((f) => f());
      unlistenClipboard.then((f) => f());
      unlistenPause.then((f) => f());
      unlistenClear.then((f) => f());
      unlistenDeleted.then((f) => f());
      unlistenPinned.then((f) => f());
      unlistenAutostart.then((f) => f());
      unlistenPasswordMgr.then((f) => f());
    };
  }, []);

  // 2. 交互动作
  const handleTogglePause = async () => {
    try {
      const nextState = !status.is_paused;
      await invoke("toggle_pause", { paused: nextState });
      setStatus((prev) => ({ ...prev, is_paused: nextState }));
      showToast(nextState ? "⏸️ 已暂停跨端同步" : "▶️ 已恢复自动同步");
    } catch (e) {
      console.error(e);
    }
  };

  const handleToggleAutostart = async () => {
    try {
      const nextState = !status.autostart_enabled;
      await invoke("toggle_autostart", { enabled: nextState });
      setStatus((prev) => ({ ...prev, autostart_enabled: nextState }));
      showToast(nextState ? "🚀 已开启开机自启" : "⭕ 已关闭开机自启");
    } catch (e) {
      console.error(e);
      showToast("❌ 修改自启动失败");
    }
  };

  const handleToggleIgnorePasswordManager = async () => {
    try {
      const nextState = !status.ignore_password_manager;
      await invoke("toggle_ignore_password_manager", { ignore: nextState });
      setStatus((prev) => ({ ...prev, ignore_password_manager: nextState }));
      showToast(nextState ? "🛡️ 已开启密码管理器避让" : "⚠️ 已允许同步所有剪贴板");
    } catch (e) {
      console.error(e);
    }
  };

  const handleRefreshPin = async (e?: React.MouseEvent) => {
    if (e) e.stopPropagation();
    setIsRefreshingPin(true);
    try {
      const newPin = await invoke<string>("refresh_pairing_pin");
      setStatus((prev) => ({ ...prev, pairing_code: newPin }));
      showToast("🔑 配对码已刷新");
    } catch (e) {
      console.error(e);
    } finally {
      setTimeout(() => setIsRefreshingPin(false), 500);
    }
  };

  const handleCopyPin = async (e: React.MouseEvent) => {
    e.stopPropagation();
    const pin = status.pairing_code.replace(" ", "");
    try {
      await invoke("copy_to_system_clipboard", { text: pin });
      setCopiedPin(true);
      showToast("📋 配对码已复制");
      setTimeout(() => setCopiedPin(false), 1500);
    } catch (e) {
      console.error(e);
    }
  };

  const handleCopy = async (item: ClipboardItem, e?: React.MouseEvent) => {
    if (e) e.stopPropagation();
    try {
      await invoke("copy_to_system_clipboard", { text: item.content });
      showToast("📋 已复制到系统剪贴板");
    } catch (e) {
      console.error(e);
    }
  };

  const handleDeleteItem = async (item: ClipboardItem, e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      await invoke("delete_history_item", { id: item.id });
      setStatus((prev) => ({
        ...prev,
        recent_items: prev.recent_items.filter((i) => i.id !== item.id),
      }));
      showToast("🗑️ 已删除此记录");
    } catch (e) {
      console.error(e);
    }
  };

  const handleTogglePin = async (item: ClipboardItem, e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      const isPinned = await invoke<boolean>("toggle_pin_history_item", { id: item.id });
      setStatus((prev) => ({
        ...prev,
        recent_items: prev.recent_items.map((i) =>
          i.id === item.id ? { ...i, is_pinned: isPinned } : i
        ),
      }));
      showToast(isPinned ? "📌 已收藏置顶" : "📍 已取消置顶");
    } catch (e) {
      console.error(e);
    }
  };

  const handleOpenLink = async (url: string, e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      await openUrl(url);
      showToast("🌐 正在默认浏览器打开");
    } catch (e) {
      console.error(e);
      showToast("❌ 无法打开链接");
    }
  };

  const handleClearHistory = async () => {
    try {
      await invoke("clear_history");
      setStatus((prev) => ({
        ...prev,
        recent_items: prev.recent_items.filter((i) => i.is_pinned),
      }));
      showToast("🗑️ 历史记录已清空（保留收藏）");
    } catch (e) {
      console.error(e);
    }
  };

  const handleClose = async () => {
    try {
      await invoke("hide_window");
    } catch (e) {
      console.error(e);
    }
  };

  const formatTime = (timestamp: number) => {
    const diff = Math.floor((Date.now() - timestamp) / 1000);
    if (diff < 10) return "刚刚";
    if (diff < 60) return `${diff}秒前`;
    if (diff < 3600) return `${Math.floor(diff / 60)}分钟前`;
    return `${Math.floor(diff / 3600)}小时前`;
  };

  const formatByteSize = (text: string) => {
    const bytes = new Blob([text]).size;
    if (bytes < 1024) return `${bytes} B`;
    return `${(bytes / 1024).toFixed(1)} KB`;
  };

  // 过滤后的列表：置顶项排在最前
  const filteredItems = useMemo(() => {
    return status.recent_items
      .filter((item) => {
        if (filterType === "windows" && item.source !== "windows") return false;
        if (filterType === "iphone" && item.source !== "iphone") return false;
        if (filterType === "pinned" && !item.is_pinned) return false;
        if (searchQuery.trim()) {
          return item.content.toLowerCase().includes(searchQuery.toLowerCase());
        }
        return true;
      })
      .sort((a, b) => {
        if (a.is_pinned && !b.is_pinned) return -1;
        if (!a.is_pinned && b.is_pinned) return 1;
        return b.timestamp - a.timestamp;
      });
  }, [status.recent_items, filterType, searchQuery]);

  // 键盘导航与回车复制
  useEffect(() => {
    setSelectedIndex(0);
  }, [searchQuery, filterType]);

  useEffect(() => {
    if (!isSettingsOpen) {
      setTimeout(() => {
        searchInputRef.current?.focus();
      }, 60);
    }
  }, [isSettingsOpen]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        if (selectedItem) {
          setSelectedItem(null);
        } else if (isSettingsOpen) {
          setIsSettingsOpen(false);
        } else {
          handleClose();
        }
        return;
      }

      if (isSettingsOpen) return;

      if (e.key === "ArrowDown") {
        e.preventDefault();
        setSelectedIndex((prev) => Math.min(prev + 1, Math.max(0, filteredItems.length - 1)));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setSelectedIndex((prev) => Math.max(0, prev - 1));
      } else if (e.key === "Enter") {
        if (selectedItem) {
          handleCopy(selectedItem);
          setSelectedItem(null);
          handleClose();
        } else if (filteredItems.length > 0 && filteredItems[selectedIndex]) {
          handleCopy(filteredItems[selectedIndex]);
          handleClose();
        }
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [selectedItem, isSettingsOpen, filteredItems, selectedIndex]);

  return (
    <div className="flyout-container">
      {/* 顶部标题栏 */}
      <header className="app-header">
        <div className="brand-section">
          {isSettingsOpen ? (
            <button className="icon-btn" onClick={() => setIsSettingsOpen(false)} title="返回">
              <ArrowLeft size={16} />
            </button>
          ) : (
            <div className="brand-logo-wrap">
              <ShieldCheck className="brand-icon" />
              <div className="brand-glow" />
            </div>
          )}
          <div className="brand-text">
            <span className="brand-title">{isSettingsOpen ? "首选项设置" : "PasteLink"}</span>
            {!isSettingsOpen && <span className="brand-badge">Fluent 2.0</span>}
          </div>
        </div>

        <div className="header-actions">
          {!isSettingsOpen && (
            <div className="shortcut-hint" title="全局唤出热键">
              <Command size={10} />
              <span>Shift+V</span>
            </div>
          )}
          {!isSettingsOpen && (
            <button
              className="icon-btn"
              title="设置"
              onClick={() => setIsSettingsOpen(true)}
            >
              <SettingsIcon size={15} />
            </button>
          )}
          <button className="icon-btn close-btn" title="隐藏到托盘" onClick={handleClose}>
            <X size={16} />
          </button>
        </div>
      </header>

      {/* 设置界面 */}
      {isSettingsOpen ? (
        <section className="settings-panel">
          <div className="setting-group">
            <span className="setting-group-title">系统集成与热键</span>
            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">开机自启动</span>
                <span className="setting-desc">Windows 登录后自动在托盘静默运行</span>
              </div>
              <div
                className={`switch-control ${status.autostart_enabled ? "on" : ""}`}
                onClick={handleToggleAutostart}
              >
                <div className="switch-knob" />
              </div>
            </div>

            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">全局呼出热键</span>
                <span className="setting-desc">快速呼出/收起右下角剪贴板浮窗</span>
              </div>
              <div className="hotkey-pill">
                <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>V</kbd>
              </div>
            </div>
          </div>

          <div className="setting-group">
            <span className="setting-group-title">隐私与安全策略</span>
            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">密码管理器智能避让</span>
                <span className="setting-desc">
                  自动拦截 1Password / Bitwarden / KeePass 复制
                </span>
              </div>
              <div
                className={`switch-control ${status.ignore_password_manager ? "on" : ""}`}
                onClick={handleToggleIgnorePasswordManager}
              >
                <div className="switch-knob" />
              </div>
            </div>
          </div>

          <div className="setting-group">
            <span className="setting-group-title">设备配对与缓存</span>
            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">重置配对密钥</span>
                <span className="setting-desc">重新生成 6 位安全 PIN 码</span>
              </div>
              <button
                className={`icon-btn secondary-btn ${isRefreshingPin ? "spin" : ""}`}
                onClick={handleRefreshPin}
                title="刷新"
              >
                <RefreshCw size={14} />
              </button>
            </div>

            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">清空跨端流水历史</span>
                <span className="setting-desc">清除本地所有记录（保留置顶项）</span>
              </div>
              <button className="icon-btn danger-btn" onClick={handleClearHistory} title="清空">
                <Trash2 size={14} />
              </button>
            </div>
          </div>
        </section>
      ) : (
        /* 主界面 */
        <>
          {/* 状态与配对卡片 */}
          <section className="status-card">
            <div className="status-row">
              <div className="status-badge">
                <span
                  className={`status-dot ${
                    status.is_paused
                      ? "paused"
                      : status.connected_devices > 0
                      ? "connected"
                      : "waiting"
                  }`}
                />
                <span className="status-text">
                  {status.is_paused
                    ? "同步已暂停"
                    : status.connected_devices > 0
                    ? `iPhone 已连接 (${status.connected_devices})`
                    : "等待 iPhone 连接..."}
                </span>
              </div>

              <button
                className={`toggle-switch ${!status.is_paused ? "active" : ""}`}
                onClick={handleTogglePause}
                title={status.is_paused ? "恢复同步" : "暂停同步"}
              >
                {status.is_paused ? <Play size={12} /> : <Pause size={12} />}
                <span>{status.is_paused ? "恢复" : "暂停"}</span>
              </button>
            </div>

            <div className="pin-row">
              <div className="pin-left">
                <KeyRound size={13} className="pin-icon" />
                <span className="pin-label">配对 PIN 码</span>
              </div>
              <div className="pin-value-box">
                <span className="pin-code">{status.pairing_code}</span>
                <button
                  className="icon-btn micro-btn"
                  title="复制配对码"
                  onClick={handleCopyPin}
                >
                  {copiedPin ? <Check size={12} className="check-icon" /> : <Copy size={12} />}
                </button>
                <button
                  className={`icon-btn micro-btn ${isRefreshingPin ? "spin" : ""}`}
                  title="刷新配对码"
                  onClick={handleRefreshPin}
                >
                  <RefreshCw size={12} />
                </button>
              </div>
            </div>
          </section>

          {/* 搜索与过滤工具栏 */}
          <section className="search-filter-section">
            <div className="search-box">
              <Search size={13} className="search-icon" />
              <input
                ref={searchInputRef}
                type="text"
                placeholder="搜索剪贴板历史 (↑↓选择 · Enter复制)..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
              />
              {searchQuery && (
                <button className="clear-search-btn" onClick={() => setSearchQuery("")}>
                  <X size={12} />
                </button>
              )}
            </div>

            <div className="filter-pills">
              <button
                className={`filter-pill ${filterType === "all" ? "active" : ""}`}
                onClick={() => setFilterType("all")}
              >
                全部
              </button>
              <button
                className={`filter-pill ${filterType === "windows" ? "active" : ""}`}
                onClick={() => setFilterType("windows")}
              >
                <Laptop size={11} /> 电脑
              </button>
              <button
                className={`filter-pill ${filterType === "iphone" ? "active" : ""}`}
                onClick={() => setFilterType("iphone")}
              >
                <Smartphone size={11} /> 手机
              </button>
              <button
                className={`filter-pill ${filterType === "pinned" ? "active" : ""}`}
                onClick={() => setFilterType("pinned")}
              >
                <Pin size={11} /> 收藏
              </button>
            </div>
          </section>

          {/* 剪贴板历史流水瀑布 */}
          <section className="history-section">
            <div className="section-header">
              <span>
                {filterType === "pinned"
                  ? "收藏记录"
                  : searchQuery
                  ? `搜索结果 (${filteredItems.length})`
                  : "最近同步流"}
              </span>
              <span style={{ fontSize: "10px", color: "var(--text-dim)", marginLeft: "auto", marginRight: "8px" }}>
                ↑↓ 选择 · ↵ 复制
              </span>
              {status.recent_items.length > 0 && (
                <button
                  className="icon-btn micro-btn"
                  title="清空非收藏历史"
                  onClick={handleClearHistory}
                >
                  <Trash2 size={12} />
                </button>
              )}
            </div>

            <div className="history-list">
              {filteredItems.length === 0 ? (
                <div className="empty-state">
                  {searchQuery ? (
                    <>
                      <ClipboardList size={34} className="empty-icon" />
                      <span className="empty-title">未找到匹配记录</span>
                      <span className="empty-desc">请尝试不同的关键词</span>
                    </>
                  ) : status.connected_devices === 0 ? (
                    <div className="onboarding-guide">
                      <div className="onboarding-badge">🚀 首次连接快速指南</div>
                      <div className="onboarding-steps">
                        <div className="onboarding-step">
                          <span className="step-num">1</span>
                          <span>在 iPhone 打开 PasteLink 应用</span>
                        </div>
                        <div className="onboarding-step">
                          <span className="step-num">2</span>
                          <span>手机将通过蓝牙自动发现此电脑并连接</span>
                        </div>
                        <div className="onboarding-step">
                          <span className="step-num">3</span>
                          <span>在手机上输入上方 6 位安全配对 PIN 码</span>
                        </div>
                      </div>
                      <span className="onboarding-tip">配对后，电脑按 Ctrl+C 即可瞬间同步至手机！</span>
                    </div>
                  ) : (
                    <>
                      <ClipboardList size={34} className="empty-icon" />
                      <span className="empty-title">设备已连接，等待同步</span>
                      <span className="empty-desc">在电脑按 Ctrl+C 或在手机复制文字即可瞬间双向同步</span>
                    </>
                  )}
                </div>
              ) : (
                filteredItems.map((item, index) => (
                  <div
                    key={item.id}
                    className={`clip-card ${item.is_pinned ? "pinned" : ""} ${
                      index === selectedIndex ? "active-selected" : ""
                    }`}
                    onClick={() => handleCopy(item)}
                    onMouseEnter={() => setSelectedIndex(index)}
                    title="点击或按 Enter 复制到剪贴板"
                  >
                    <div className="clip-meta">
                      <div className="clip-meta-left">
                        {/* 来源徽标 */}
                        <span
                          className={`clip-source ${
                            item.source === "windows" ? "source-windows" : "source-iphone"
                          }`}
                        >
                          {item.source === "windows" ? (
                            <Laptop size={11} />
                          ) : (
                            <Smartphone size={11} />
                          )}
                          {item.source === "windows" ? "PC" : "iOS"}
                        </span>

                        {/* 数据类型徽标 */}
                        {item.item_type === "url" && (
                          <span className="type-badge badge-url">
                            <Link2 size={10} /> URL
                          </span>
                        )}
                        {item.item_type === "code" && (
                          <span className="type-badge badge-code">
                            <FileCode size={10} /> CODE
                          </span>
                        )}
                        {item.item_type === "otp" && (
                          <span className="type-badge badge-otp">
                            <Sparkles size={10} /> 验证码
                          </span>
                        )}

                        {item.is_pinned && (
                          <span className="type-badge badge-pinned">
                            <Pin size={10} /> 置顶
                          </span>
                        )}
                      </div>

                      <div className="clip-meta-right">
                        <span className="clip-size">
                          {item.char_count}字 · {formatByteSize(item.content)}
                        </span>
                        <span className="clip-time">{formatTime(item.timestamp)}</span>
                      </div>
                    </div>

                    <div
                      className={`clip-content ${
                        item.item_type === "code" || item.item_type === "otp" ? "font-mono" : ""
                      }`}
                    >
                      {item.preview}
                    </div>

                    {/* 悬停快捷动作条 */}
                    <div className="card-actions">
                      {item.item_type === "url" && (
                        <button
                          className="card-action-btn"
                          title="在浏览器中打开"
                          onClick={(e) => handleOpenLink(item.content.trim(), e)}
                        >
                          <ExternalLink size={12} />
                        </button>
                      )}
                      <button
                        className="card-action-btn"
                        title="查看全文详情"
                        onClick={(e) => {
                          e.stopPropagation();
                          setSelectedItem(item);
                        }}
                      >
                        <Eye size={12} />
                      </button>
                      <button
                        className={`card-action-btn ${item.is_pinned ? "active" : ""}`}
                        title={item.is_pinned ? "取消收藏" : "收藏置顶"}
                        onClick={(e) => handleTogglePin(item, e)}
                      >
                        <Pin size={12} />
                      </button>
                      <button
                        className="card-action-btn delete-btn"
                        title="删除记录"
                        onClick={(e) => handleDeleteItem(item, e)}
                      >
                        <Trash2 size={12} />
                      </button>
                    </div>
                  </div>
                ))
              )}
            </div>
          </section>
        </>
      )}

      {/* 底部信息 */}
      <footer className="app-footer">
        <div className="footer-left">
          <span className="pulse-dot" />
          <span>BLE 5.0 · 端到端安全加密</span>
        </div>
        <span className="footer-ver">v1.0.0</span>
      </footer>

      {/* 查看详情弹窗 Modal */}
      {selectedItem && (
        <div className="modal-overlay" onClick={() => setSelectedItem(null)}>
          <div className="modal-card" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <div className="modal-title-row">
                <FileText size={15} />
                <span>剪贴板详情</span>
                <span className="modal-badge">{selectedItem.char_count} 字符</span>
              </div>
              <button className="icon-btn" onClick={() => setSelectedItem(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <pre className="modal-text">{selectedItem.content}</pre>
            </div>
            <div className="modal-footer">
              <button
                className="btn-primary"
                onClick={() => {
                  handleCopy(selectedItem);
                  setSelectedItem(null);
                }}
              >
                <Copy size={13} />
                <span>复制全部内容</span>
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 交互反馈 Toast */}
      {toastMsg && <div className="toast">{toastMsg}</div>}
    </div>
  );
}

