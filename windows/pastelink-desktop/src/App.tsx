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
  PinOff,
  AlertTriangle,
  ExternalLink,
  Copy,
  Check,
  Sparkles,
  FileCode,
  Link2,
  KeyRound,
  FileText,
  Eye,
  Sun,
  Moon,
  Monitor,
  Image as ImageIcon,
  Download,
} from "lucide-react";
import { ClipboardItem, StatusPayload, ThemeMode, TransferProgressPayload } from "./types";
import { filterHistoryItems, mergeHistoryItem, shouldUseHistoryShortcut, trimHistory } from "./history";
import "./App.css";

export default function App() {
  const [status, setStatus] = useState<StatusPayload>({
    is_paused: false,
    ignore_password_manager: true,
    autostart_enabled: false,
    connected_devices: 0,
    lan_connected: false,
    pairing_code: "--- ---",
    recent_items: [],
  });

  const [themeMode, setThemeMode] = useState<ThemeMode>(() => {
    const saved = localStorage.getItem("pastelink_theme");
    if (saved === "light" || saved === "dark" || saved === "system") {
      return saved as ThemeMode;
    }
    return "system";
  });

  const [systemPrefersDark, setSystemPrefersDark] = useState<boolean>(() => {
    if (typeof window !== "undefined" && window.matchMedia) {
      return window.matchMedia("(prefers-color-scheme: dark)").matches;
    }
    return true;
  });

  const effectiveTheme = useMemo<"light" | "dark">(() => {
    if (themeMode === "system") {
      return systemPrefersDark ? "dark" : "light";
    }
    return themeMode;
  }, [themeMode, systemPrefersDark]);

  // 失焦自动隐藏 (默认开启)
  const [autoHideOnBlur, setAutoHideOnBlur] = useState<boolean>(() => {
    const saved = localStorage.getItem("pastelink_autohide_blur");
    return saved !== null ? saved === "true" : true;
  });

  // 窗口图钉常驻状态 (默认未置顶，失焦即自动收起)
  const [isWindowPinned, setIsWindowPinned] = useState<boolean>(() => {
    const saved = localStorage.getItem("pastelink_window_pinned");
    return saved === "true";
  });

  // 复制后自动关闭浮窗 (默认开启，提升粘贴效率)
  const [closeAfterCopy, setCloseAfterCopy] = useState<boolean>(() => {
    const saved = localStorage.getItem("pastelink_close_after_copy");
    return saved !== null ? saved === "true" : true;
  });

  // 清空历史二次确认弹窗
  const [showClearConfirm, setShowClearConfirm] = useState(false);
  const [showPinResetConfirm, setShowPinResetConfirm] = useState(false);

  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [toastMsg, setToastMsg] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [filterType, setFilterType] = useState<"all" | "windows" | "iphone" | "image" | "pinned">("all");
  const [transferProgress, setTransferProgress] = useState<TransferProgressPayload | null>(null);
  const [selectedItem, setSelectedItem] = useState<ClipboardItem | null>(null);
  const [copiedPin, setCopiedPin] = useState(false);
  const [isRefreshingPin, setIsRefreshingPin] = useState(false);
  const [selectedIndex, setSelectedIndex] = useState<number>(0);

  const searchInputRef = useRef<HTMLInputElement>(null);
  const historyListRef = useRef<HTMLDivElement>(null);
  const dialogRef = useRef<HTMLDivElement>(null);
  const toastTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const searchFocusTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const copyInProgressRef = useRef(false);
  const isModalOpen = showClearConfirm || showPinResetConfirm || selectedItem !== null;

  const showToast = (msg: string) => {
    if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
    setToastMsg(msg);
    toastTimerRef.current = setTimeout(() => setToastMsg(null), 3000);
  };

  useEffect(() => () => {
    if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
  }, []);

  useEffect(() => {
    if (!isModalOpen) return;
    clearTimeout(searchFocusTimerRef.current);
    const previousFocus = document.activeElement as HTMLElement | null;
    dialogRef.current?.querySelector<HTMLButtonElement>("[data-autofocus]")?.focus();
    return () => previousFocus?.focus();
  }, [isModalOpen]);

  const handleDialogKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "Tab") return;
    const controls = Array.from(event.currentTarget.querySelectorAll<HTMLElement>(
      'button:not(:disabled), a[href], [tabindex="0"]',
    ));
    const first = controls[0];
    const last = controls[controls.length - 1];
    if (!first) {
      event.preventDefault();
      event.currentTarget.focus();
      return;
    }
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last?.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first?.focus();
    }
  };

  const handleClose = async () => {
    try {
      await invoke("hide_window");
    } catch (e) {
      console.error(e);
    }
  };

  // 监听窗口失焦 (Blur) 与聚焦 (Focus) 自动响应
  useEffect(() => {
    let focusTimer: ReturnType<typeof setTimeout> | undefined;
    const handleBlur = () => {
      // 若开启了失焦隐藏、窗口未被图钉固定、且没有弹出二次确认框，自动收起到托盘
      if (autoHideOnBlur && !isWindowPinned && !isModalOpen) {
        handleClose();
      }
    };

    const handleFocus = () => {
      // 唤出或激活时，自动让搜索输入框获得焦点
      if (!isSettingsOpen && !isModalOpen) {
        focusTimer = setTimeout(() => {
          searchInputRef.current?.focus();
        }, 50);
      }
    };

    window.addEventListener("blur", handleBlur);
    window.addEventListener("focus", handleFocus);
    return () => {
      clearTimeout(focusTimer);
      window.removeEventListener("blur", handleBlur);
      window.removeEventListener("focus", handleFocus);
    };
  }, [autoHideOnBlur, isWindowPinned, isSettingsOpen, isModalOpen]);

  // 监听系统深浅色主题变化
  useEffect(() => {
    if (typeof window === "undefined" || !window.matchMedia) return;
    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    const handleChange = (e: MediaQueryListEvent) => {
      setSystemPrefersDark(e.matches);
    };
    mediaQuery.addEventListener("change", handleChange);
    return () => mediaQuery.removeEventListener("change", handleChange);
  }, []);

  // 将当前有效主题应用到文档根节点
  useEffect(() => {
    document.documentElement.setAttribute("data-theme", effectiveTheme);
  }, [effectiveTheme]);

  const handleThemeChange = (mode: ThemeMode) => {
    setThemeMode(mode);
    localStorage.setItem("pastelink_theme", mode);
    const labelMap: Record<ThemeMode, string> = {
      system: "🌗 已设为跟随系统外观",
      light: "☀️ 已切换为浅色模式",
      dark: "🌙 已切换为深色模式",
    };
    showToast(labelMap[mode]);
  };

  const handleCycleTheme = () => {
    const cycleMap: Record<ThemeMode, ThemeMode> = {
      system: "light",
      light: "dark",
      dark: "system",
    };
    handleThemeChange(cycleMap[themeMode]);
  };

  // 1. 初始化拉取状态并注册事件监听
  useEffect(() => {
    const fetchStatus = async () => {
      try {
        const data = await invoke<StatusPayload>("get_status");
        setStatus(data);
      } catch (e) {
        console.error("Failed to fetch initial status:", e);
        showToast("无法读取应用状态，请重新打开 PasteLink");
      }
    };

    fetchStatus();

    // WLAN 探测在手机后台停止后会过期；仅刷新该字段，避免覆盖历史事件。
    let active = true;
    const refreshLanStatus = async () => {
      try {
        const connected = await invoke<boolean>("get_lan_status");
        if (active) setStatus((prev) => ({ ...prev, lan_connected: connected }));
      } catch (e) {
        console.error("Failed to refresh WLAN status:", e);
      }
    };
    const lanTimer = window.setInterval(refreshLanStatus, 3000);

    // 订阅 Tauri 后端广播事件
    const unlistenSubscribers = listen<number>("ble-subscribers-changed", (event) => {
      setStatus((prev) => ({ ...prev, connected_devices: event.payload }));
    });

    const unlistenClipboard = listen<ClipboardItem>("clipboard-updated", (event) => {
      setStatus((prev) => {
        return {
          ...prev,
          recent_items: mergeHistoryItem(prev.recent_items, event.payload),
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
          recent_items: trimHistory(prev.recent_items.map((i) =>
            i.id === event.payload.id ? { ...i, is_pinned: event.payload.is_pinned } : i
          )),
        }));
      }
    );

    const unlistenAutostart = listen<boolean>("autostart-changed", (event) => {
      setStatus((prev) => ({ ...prev, autostart_enabled: event.payload }));
    });

    const unlistenPasswordMgr = listen<boolean>("ignore-password-manager-changed", (event) => {
      setStatus((prev) => ({ ...prev, ignore_password_manager: event.payload }));
    });

    const unlistenTransfer = listen<TransferProgressPayload>("transfer-progress", (event) => {
      if (event.payload.is_active) {
        setTransferProgress(event.payload);
      } else {
        setTransferProgress(null);
      }
    });

    return () => {
      active = false;
      window.clearInterval(lanTimer);
      unlistenSubscribers.then((f) => f());
      unlistenClipboard.then((f) => f());
      unlistenPause.then((f) => f());
      unlistenClear.then((f) => f());
      unlistenDeleted.then((f) => f());
      unlistenPinned.then((f) => f());
      unlistenAutostart.then((f) => f());
      unlistenPasswordMgr.then((f) => f());
      unlistenTransfer.then((f) => f());
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
      showToast("修改同步状态失败，请重试");
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
      showToast("修改隐私设置失败，请重试");
    }
  };

  const handleRequestRefreshPin = (e: React.MouseEvent) => {
    e.stopPropagation();
    if (!isRefreshingPin) setShowPinResetConfirm(true);
  };

  const handleRefreshPin = async () => {
    if (isRefreshingPin) return;
    setIsRefreshingPin(true);
    try {
      const newPin = await invoke<string>("refresh_pairing_pin");
      setStatus((prev) => ({ ...prev, pairing_code: newPin, lan_connected: false }));
      setShowPinResetConfirm(false);
      showToast("配对码已重置，请在 iPhone 上输入新码重新配对");
    } catch (e) {
      console.error(e);
      showToast("重置配对码失败，请重试");
    } finally {
      setIsRefreshingPin(false);
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
      showToast("复制配对码失败，请重试");
    }
  };

  const handleCopy = async (item: ClipboardItem, e?: React.MouseEvent) => {
    if (e) e.stopPropagation();
    if (copyInProgressRef.current) return false;
    copyInProgressRef.current = true;
    try {
      await invoke("copy_item_by_id", { id: item.id });
      showToast(item.item_type === "image" ? "🖼️ 图像已复制到剪贴板，可 Ctrl+V 粘贴" : "📋 已复制到系统剪贴板");
      // 复制后自动收起窗口（未固定窗口且启用了该选项时）
      if (closeAfterCopy && !isWindowPinned) {
        setTimeout(() => {
          handleClose();
        }, 160);
      }
      return true;
    } catch (e) {
      console.error(e);
      showToast(item.item_type === "image"
        ? "复制图片失败，图片可能已失效或剪贴板正被占用，请重试"
        : "复制失败，记录可能已删除或剪贴板正被占用，请重试");
      return false;
    } finally {
      copyInProgressRef.current = false;
    }
  };

  const handleToggleAutoHideOnBlur = () => {
    const next = !autoHideOnBlur;
    setAutoHideOnBlur(next);
    localStorage.setItem("pastelink_autohide_blur", String(next));
    showToast(next ? "👁️ 已开启失焦自动收起" : "🛑 已关闭失焦自动收起 (窗口常驻)");
  };

  const handleToggleWindowPin = () => {
    const next = !isWindowPinned;
    setIsWindowPinned(next);
    localStorage.setItem("pastelink_window_pinned", String(next));
    showToast(next ? "📌 窗口已固定常驻 (失焦不关闭)" : "🔓 窗口已解除固定 (失焦自动关闭)");
  };

  const handleToggleCloseAfterCopy = () => {
    const next = !closeAfterCopy;
    setCloseAfterCopy(next);
    localStorage.setItem("pastelink_close_after_copy", String(next));
    showToast(next ? "⚡ 已开启复制后自动收起" : "📋 已关闭复制后自动收起");
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
      showToast("删除记录失败，请重试");
    }
  };

  const handleTogglePin = async (item: ClipboardItem, e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      const isPinned = await invoke<boolean>("toggle_pin_history_item", { id: item.id });
      setStatus((prev) => ({
        ...prev,
        recent_items: trimHistory(prev.recent_items.map((i) =>
          i.id === item.id ? { ...i, is_pinned: isPinned } : i
        )),
      }));
      showToast(isPinned ? "📌 已收藏置顶" : "📍 已取消置顶");
    } catch (e) {
      console.error(e);
      showToast("修改收藏失败，请重试");
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

  const handleRequestClearHistory = (e?: React.MouseEvent) => {
    if (e) e.stopPropagation();
    if (!status.recent_items.some((item) => !item.is_pinned)) {
      showToast("没有可清空的普通记录，收藏会保留");
      return;
    }
    setShowClearConfirm(true);
  };

  const handleConfirmClearHistory = async () => {
    try {
      await invoke("clear_history");
      setStatus((prev) => ({
        ...prev,
        recent_items: prev.recent_items.filter((i) => i.is_pinned),
      }));
      setShowClearConfirm(false);
      showToast("🗑️ 历史记录已清空（保留收藏）");
    } catch (e) {
      console.error(e);
      showToast("清空历史失败，请重试");
    }
  };

  const formatTime = (timestamp: number) => {
    const diff = Math.floor((Date.now() - timestamp) / 1000);
    if (diff < 10) return "刚刚";
    if (diff < 60) return `${diff}秒前`;
    if (diff < 3600) return `${Math.floor(diff / 60)}分钟前`;
    return `${Math.floor(diff / 3600)}小时前`;
  };

  const formatByteSize = (bytesOrText: string | number) => {
    const bytes = typeof bytesOrText === "number" ? bytesOrText : new Blob([bytesOrText]).size;
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
  };

  // 过滤后的列表：置顶项排在最前
  const filteredItems = useMemo(() => {
    return filterHistoryItems(status.recent_items, filterType, searchQuery);
  }, [status.recent_items, filterType, searchQuery]);
  const activeIndex = Math.min(selectedIndex, Math.max(0, filteredItems.length - 1));

  useEffect(() => {
    setSelectedIndex((previous) => Math.min(previous, Math.max(0, filteredItems.length - 1)));
  }, [filteredItems.length]);

  useEffect(() => {
    historyListRef.current?.querySelector(".active-selected")?.scrollIntoView({ block: "nearest" });
  }, [activeIndex, filteredItems]);

  // 键盘导航与回车复制
  useEffect(() => {
    setSelectedIndex(0);
  }, [searchQuery, filterType]);

  useEffect(() => {
    if (!isSettingsOpen) {
      searchFocusTimerRef.current = setTimeout(() => {
        searchInputRef.current?.focus();
      }, 60);
      return () => clearTimeout(searchFocusTimerRef.current);
    }
  }, [isSettingsOpen]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.isComposing || e.keyCode === 229 || e.defaultPrevented) return;
      if (e.key === "Escape") {
        e.preventDefault();
        if (showPinResetConfirm) {
          if (!isRefreshingPin) setShowPinResetConfirm(false);
        } else if (showClearConfirm) {
          setShowClearConfirm(false);
        } else if (selectedItem) {
          setSelectedItem(null);
        } else if (searchQuery) {
          setSearchQuery("");
        } else if (isSettingsOpen) {
          setIsSettingsOpen(false);
        } else {
          handleClose();
        }
        return;
      }

      if (isSettingsOpen || showClearConfirm || showPinResetConfirm) return;
      const target = e.target instanceof Element ? e.target : null;
      const inOtherControl = target !== searchInputRef.current && Boolean(target?.closest(
        'button, a, input, textarea, select, [role="switch"], [contenteditable="true"]',
      ));
      if (!shouldUseHistoryShortcut(e, inOtherControl)) return;
      if (selectedItem && e.key !== "Enter") return;

      if (e.key === "ArrowDown") {
        e.preventDefault();
        setSelectedIndex((prev) => Math.min(prev + 1, Math.max(0, filteredItems.length - 1)));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setSelectedIndex((prev) => Math.max(0, prev - 1));
      } else if (e.key === "Enter") {
        if (e.repeat) return;
        e.preventDefault();
        if (selectedItem) {
          handleCopy(selectedItem).then((copied) => { if (copied) setSelectedItem(null); });
        } else if (filteredItems[activeIndex]) {
          handleCopy(filteredItems[activeIndex]);
        }
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [selectedItem, isSettingsOpen, filteredItems, activeIndex, showClearConfirm, showPinResetConfirm, isRefreshingPin, searchQuery, closeAfterCopy, isWindowPinned]);

  return (
    <div className="flyout-container" data-theme={effectiveTheme}>
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
              <span>Ctrl+Shift+V</span>
            </div>
          )}
          <button
            className={`icon-btn ${isWindowPinned ? "pinned-btn" : ""}`}
            title={
              isWindowPinned
                ? "📌 浮窗已固定常驻 (点击解锁，失焦自动关闭)"
                : "🔓 浮窗随失焦自动收起 (点击可固定在屏幕)"
            }
            onClick={handleToggleWindowPin}
          >
            {isWindowPinned ? <Pin size={15} /> : <PinOff size={15} />}
          </button>
          <button
            className="icon-btn"
            title={`外观模式: ${
              themeMode === "system"
                ? `跟随系统 (${effectiveTheme === "dark" ? "深色" : "浅色"})`
                : themeMode === "dark"
                ? "深色模式"
                : "浅色模式"
            } · 点击快速流转`}
            onClick={handleCycleTheme}
          >
            {themeMode === "system" ? (
              <Monitor size={15} />
            ) : themeMode === "dark" ? (
              <Moon size={15} />
            ) : (
              <Sun size={15} />
            )}
          </button>
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
            <span className="setting-group-title">窗口与交互行为</span>
            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">失焦自动收起浮窗</span>
                <span className="setting-desc">点击桌面或切换应用时自动隐藏至托盘</span>
              </div>
              <button type="button" role="switch" aria-label="失焦自动收起浮窗" aria-checked={autoHideOnBlur}
                className={`switch-control ${autoHideOnBlur ? "on" : ""}`}
                onClick={handleToggleAutoHideOnBlur}
              >
                <div className="switch-knob" />
              </button>
            </div>

            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">点击复制后自动收起</span>
                <span className="setting-desc">点击条目复制后自动收起，方便立即在文档中粘贴</span>
              </div>
              <button type="button" role="switch" aria-label="点击复制后自动收起" aria-checked={closeAfterCopy}
                className={`switch-control ${closeAfterCopy ? "on" : ""}`}
                onClick={handleToggleCloseAfterCopy}
              >
                <div className="switch-knob" />
              </button>
            </div>

            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">浮窗固定常驻</span>
                <span className="setting-desc">
                  {isWindowPinned
                    ? "当前已固定 (失焦不自动关闭，方便连续对照)"
                    : "当前未固定 (失焦或复制后自动隐藏)"}
                </span>
              </div>
              <button
                className={`icon-btn secondary-btn ${isWindowPinned ? "pinned-btn" : ""}`}
                onClick={handleToggleWindowPin}
                title="切换图钉常驻"
              >
                {isWindowPinned ? <Pin size={14} /> : <PinOff size={14} />}
              </button>
            </div>
          </div>
          <div className="setting-group">
            <span className="setting-group-title">外观与显示模式</span>
            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">深色模式 / 主题模式</span>
                <span className="setting-desc">
                  {themeMode === "system"
                    ? `跟随 Windows 偏好 (当前呈现: ${effectiveTheme === "dark" ? "深色" : "浅色"})`
                    : themeMode === "dark"
                    ? "深色模式 (强行开启暗色)"
                    : "浅色模式 (明亮清晰)"}
                </span>
              </div>
              <div className="theme-segmented-control">
                <button
                  className={`theme-segment-btn ${themeMode === "system" ? "active" : ""}`}
                  onClick={() => handleThemeChange("system")}
                  title="跟随 Windows 系统"
                >
                  <Monitor size={12} />
                  <span>系统</span>
                </button>
                <button
                  className={`theme-segment-btn ${themeMode === "light" ? "active" : ""}`}
                  onClick={() => handleThemeChange("light")}
                  title="强制浅色模式"
                >
                  <Sun size={12} />
                  <span>浅色</span>
                </button>
                <button
                  className={`theme-segment-btn ${themeMode === "dark" ? "active" : ""}`}
                  onClick={() => handleThemeChange("dark")}
                  title="强制深色模式"
                >
                  <Moon size={12} />
                  <span>深色</span>
                </button>
              </div>
            </div>
          </div>

          <div className="setting-group">
            <span className="setting-group-title">系统集成与热键</span>
            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">开机自启动</span>
                <span className="setting-desc">Windows 登录后自动在托盘静默运行</span>
              </div>
              <button type="button" role="switch" aria-label="开机自启动" aria-checked={status.autostart_enabled}
                className={`switch-control ${status.autostart_enabled ? "on" : ""}`}
                onClick={handleToggleAutostart}
              >
                <div className="switch-knob" />
              </button>
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
              <button type="button" role="switch" aria-label="密码管理器智能避让" aria-checked={status.ignore_password_manager}
                className={`switch-control ${status.ignore_password_manager ? "on" : ""}`}
                onClick={handleToggleIgnorePasswordManager}
              >
                <div className="switch-knob" />
              </button>
            </div>
          </div>

          <div className="setting-group">
            <span className="setting-group-title">设备配对与缓存</span>
            <div className="setting-card">
              <div className="setting-info">
                <span className="setting-title">重置配对密钥</span>
                <span className="setting-desc">生成新码后，iPhone 需要重新配对</span>
              </div>
              <button
                className={`icon-btn secondary-btn ${isRefreshingPin ? "spin" : ""}`}
                onClick={handleRequestRefreshPin}
                disabled={isRefreshingPin}
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
              <button className="icon-btn danger-btn" onClick={handleRequestClearHistory} title="清空历史">
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
                      : status.connected_devices > 0 || status.lan_connected
                      ? "connected"
                      : "waiting"
                  }`}
                />
                <span className="status-text">
                  {status.is_paused
                    ? "同步已暂停"
                    : status.connected_devices > 0 || status.lan_connected
                    ? "iPhone 已连接"
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

            <div className="connection-channels" aria-label="连接通道">
              <span className={`connection-channel ${status.connected_devices > 0 ? "available" : "unavailable"}`}>
                蓝牙 {status.connected_devices > 0 ? "已连接" : "未连接"}
              </span>
              <span className={`connection-channel ${status.lan_connected ? "available" : "unavailable"}`}>
                WLAN {status.lan_connected ? "可用" : "不可用"}
              </span>
            </div>

            <div className="pin-row">
              <div className="pin-left">
                <KeyRound size={13} className="pin-icon" />
                <span className="pin-label">配对 PIN 码</span>
              </div>
              <div
                className="pin-value-box"
                onClick={handleCopyPin}
                title="点击一键复制配对 PIN 码"
                style={{ cursor: "pointer" }}
              >
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
                  onClick={handleRequestRefreshPin}
                  disabled={isRefreshingPin}
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
                aria-label="搜索剪贴板历史"
                placeholder="搜索剪贴板历史 (↑↓选择 · Enter复制)..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
              />
              {searchQuery && (
                <button
                  className="clear-search-btn"
                  title="清空搜索词 (Esc)"
                  onClick={() => {
                    setSearchQuery("");
                    searchInputRef.current?.focus();
                  }}
                >
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
                className={`filter-pill ${filterType === "image" ? "active" : ""}`}
                onClick={() => setFilterType("image")}
              >
                <ImageIcon size={11} /> 图片
              </button>
              <button
                className={`filter-pill ${filterType === "pinned" ? "active" : ""}`}
                onClick={() => setFilterType("pinned")}
              >
                <Pin size={11} /> 收藏
              </button>
            </div>
          </section>

          {/* 实时分片传输抽屉 */}
          {transferProgress && (
            <section className="transfer-drawer">
              <div className="transfer-info">
                <div className="transfer-title-row">
                  <span className="pulse-dot" />
                  <span>
                    {transferProgress.direction === "send" ? "正在推送图片至 iPhone..." : "正在接收 iPhone 图片..."}
                  </span>
                  <span className="transfer-percent">
                    {transferProgress.percent}%
                  </span>
                </div>
                <div className="transfer-meta">
                  <span>总计约 {formatByteSize(transferProgress.total_bytes)}</span>
                  <span>分片 {transferProgress.transferred_chunks} / {transferProgress.total_chunks}</span>
                </div>
              </div>
              <div className="transfer-progress-bar">
                <div
                  className="transfer-progress-fill"
                  style={{
                    width: `${Math.min(100, Math.max(0, transferProgress.percent))}%`,
                  }}
                />
              </div>
            </section>
          )}

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
                ↑↓ 选择 · ↵ 复制 · 详情按钮查看全文
              </span>
              {status.recent_items.length > 0 && (
                <button
                  className="icon-btn micro-btn"
                  title="清空非收藏历史"
                  onClick={handleRequestClearHistory}
                >
                  <Trash2 size={12} />
                </button>
              )}
            </div>

            <div className="history-list" ref={historyListRef}>
              {filteredItems.length === 0 ? (
                <div className="empty-state">
                  {searchQuery ? (
                    <>
                      <ClipboardList size={34} className="empty-icon" />
                      <span className="empty-title">未找到匹配记录</span>
                      <span className="empty-desc">按 Esc 可清空搜索返回全部</span>
                    </>
                  ) : filterType !== "all" ? (
                    <>
                      <ClipboardList size={34} className="empty-icon" />
                      <span className="empty-title">{filterType === "pinned" ? "暂无收藏记录" : "该分类暂无记录"}</span>
                      <button className="btn-secondary" onClick={() => setFilterType("all")}>查看全部记录</button>
                    </>
                  ) : status.connected_devices === 0 && !status.lan_connected ? (
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
                      <span className="empty-desc">电脑复制后自动同步；手机复制后请在 App 中点“发送当前剪贴板”</span>
                    </>
                  )}
                </div>
              ) : (
                filteredItems.map((item, index) => (
                  <div
                    key={item.id}
                    className={`clip-card ${item.is_pinned ? "pinned" : ""} ${
                      index === activeIndex ? "active-selected" : ""
                    }`}
                    onClick={() => handleCopy(item)}
                    onMouseEnter={() => setSelectedIndex(index)}
                    title="点击或按 Enter 复制 · 点击详情按钮查看全文"
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
                        {item.item_type === "image" && (
                          <span className="type-badge badge-image">
                            <ImageIcon size={10} /> 图片
                          </span>
                        )}
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
                          {item.item_type === "image"
                            ? `${item.width || 0}×${item.height || 0} · ${formatByteSize(item.file_size || 0)}`
                            : `${item.char_count}字 · ${formatByteSize(item.content)}`}
                        </span>
                        <span className="clip-time">{formatTime(item.timestamp)}</span>
                      </div>
                    </div>

                    {item.item_type === "image" && item.image_data ? (
                      <div className="clip-image-card-body">
                        <div className="clip-thumbnail-box">
                          <img src={item.image_data} alt="clip preview" className="clip-thumbnail" />
                        </div>
                        <div className="clip-image-info">
                          <span className="clip-image-res">{item.width} × {item.height} 像素</span>
                          <span className="clip-image-fmt">无损 PNG · {formatByteSize(item.file_size || 0)}</span>
                        </div>
                      </div>
                    ) : (
                      <div
                        className={`clip-content ${
                          item.item_type === "code" || item.item_type === "otp" ? "font-mono" : ""
                        }`}
                      >
                        {item.preview}
                      </div>
                    )}

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
                      {item.item_type === "image" && item.image_data && (
                        <a
                          className="card-action-btn"
                          title="保存图片到本地"
                          href={item.image_data}
                          download={`pastelink_${item.timestamp}.png`}
                          onClick={(e) => e.stopPropagation()}
                        >
                          <Download size={12} />
                        </a>
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
        <span className="footer-ver">v1.1.0</span>
      </footer>

      {/* 查看详情弹窗 Modal */}
      {selectedItem && (
        <div className="modal-overlay" onClick={() => setSelectedItem(null)}>
          <div className="modal-card" ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" aria-label="剪贴板详情"
            onKeyDown={handleDialogKeyDown} onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <div className="modal-title-row">
                {selectedItem.item_type === "image" ? <ImageIcon size={15} /> : <FileText size={15} />}
                <span>{selectedItem.item_type === "image" ? "图片详情预览" : "剪贴板详情"}</span>
                <span className="modal-badge">
                  {selectedItem.item_type === "image"
                    ? `${selectedItem.width || 0}×${selectedItem.height || 0} · ${formatByteSize(selectedItem.file_size || 0)}`
                    : `${selectedItem.char_count} 字符`}
                </span>
              </div>
              <button className="icon-btn" aria-label="关闭详情" onClick={() => setSelectedItem(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              {selectedItem.item_type === "image" && selectedItem.image_data ? (
                <div className="modal-image-container">
                  <img src={selectedItem.image_data} alt="Full view" className="modal-full-image" />
                  <div className="modal-image-meta">
                    <span>尺寸: {selectedItem.width} × {selectedItem.height} 像素</span>
                    <span>格式: 无损 PNG</span>
                    <span>大小: {formatByteSize(selectedItem.file_size || 0)}</span>
                  </div>
                </div>
              ) : (
                <pre className="modal-text">{selectedItem.content}</pre>
              )}
            </div>
            <div className="modal-footer">
              <span className="modal-footer-hints">按 Enter 快速复制 · 按 Esc 关闭</span>
              {selectedItem.item_type === "image" && selectedItem.image_data && (
                <a
                  className="btn-secondary"
                  style={{ textDecoration: "none", display: "inline-flex", alignItems: "center", gap: "6px" }}
                  href={selectedItem.image_data}
                  download={`pastelink_${selectedItem.timestamp}.png`}
                >
                  <Download size={13} />
                  <span>下载 PNG</span>
                </a>
              )}
              <button
                className="btn-primary"
                data-autofocus
                onClick={async () => {
                  if (await handleCopy(selectedItem)) setSelectedItem(null);
                }}
              >
                <Copy size={13} />
                <span>{selectedItem.item_type === "image" ? "复制图片到剪贴板" : "复制全部内容"}</span>
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 清空历史防误触确认弹窗 */}
      {showClearConfirm && (
        <div className="confirm-dialog-overlay" onClick={() => setShowClearConfirm(false)}>
          <div className="confirm-dialog-card" ref={dialogRef} tabIndex={-1} role="alertdialog" aria-modal="true"
            aria-labelledby="clear-history-title" aria-describedby="clear-history-description"
            onKeyDown={handleDialogKeyDown} onClick={(e) => e.stopPropagation()}>
            <div className="confirm-dialog-header">
              <AlertTriangle size={17} />
              <span id="clear-history-title">清空历史记录确认</span>
            </div>
            <div className="confirm-dialog-body" id="clear-history-description">
              确定要清空本地所有未收藏的剪贴板历史记录吗？
              <br />
              <span style={{ fontSize: "11px", color: "var(--accent-gold)", marginTop: "4px", display: "inline-block" }}>
                📌 已收藏置顶的项目将继续保留
              </span>
            </div>
            <div className="confirm-dialog-actions">
              <button className="btn-secondary" data-autofocus onClick={() => setShowClearConfirm(false)}>
                取消 (Esc)
              </button>
              <button className="btn-danger" onClick={handleConfirmClearHistory}>
                确定清空
              </button>
            </div>
          </div>
        </div>
      )}

      {showPinResetConfirm && (
        <div className="confirm-dialog-overlay" onClick={() => { if (!isRefreshingPin) setShowPinResetConfirm(false); }}>
          <div className="confirm-dialog-card" ref={dialogRef} tabIndex={-1} role="alertdialog" aria-modal="true"
            aria-labelledby="reset-pin-title" aria-describedby="reset-pin-description"
            onKeyDown={handleDialogKeyDown} onClick={(e) => e.stopPropagation()}>
            <div className="confirm-dialog-header"><KeyRound size={17} /><span id="reset-pin-title">重置配对码？</span></div>
            <div className="confirm-dialog-body" id="reset-pin-description">
              当前配对码将失效，已配对的 iPhone 需要输入新码才能继续同步。
            </div>
            <div className="confirm-dialog-actions">
              <button className="btn-secondary" data-autofocus disabled={isRefreshingPin}
                onClick={() => setShowPinResetConfirm(false)}>取消 (Esc)</button>
              <button className="btn-danger" disabled={isRefreshingPin} onClick={handleRefreshPin}>
                {isRefreshingPin ? "正在重置…" : "重置配对码"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 交互反馈 Toast */}
      <div role="status" aria-live="polite" aria-atomic="true">
        {toastMsg && <div className="toast">{toastMsg}</div>}
      </div>
    </div>
  );
}

