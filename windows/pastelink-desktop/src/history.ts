import type { ClipboardItem } from "./types";

export type HistoryFilter = "all" | "windows" | "iphone" | "image" | "pinned";

// Keep in sync with MAX_HISTORY in core/state.rs. Pins do not consume the quota.
export function trimHistory(items: ClipboardItem[]): ClipboardItem[] {
  let unpinned = 0;
  return items.filter((item) => item.is_pinned || ++unpinned <= 30);
}

export function mergeHistoryItem(items: ClipboardItem[], incoming: ClipboardItem): ClipboardItem[] {
  const previous = items.find((item) => item.sha256 === incoming.sha256);
  const updated = { ...incoming, is_pinned: incoming.is_pinned || previous?.is_pinned || false };
  return trimHistory([updated, ...items.filter((item) => item.sha256 !== incoming.sha256)]);
}

export function filterHistoryItems(items: ClipboardItem[], filter: HistoryFilter, query: string): ClipboardItem[] {
  const normalizedQuery = query.trim().toLowerCase();
  return items.filter((item) => {
    if (filter === "windows" && item.source !== "windows") return false;
    if (filter === "iphone" && item.source !== "iphone") return false;
    if (filter === "image" && item.item_type !== "image") return false;
    if (filter === "pinned" && !item.is_pinned) return false;
    if (normalizedQuery) {
      return item.content.toLowerCase().includes(normalizedQuery) ||
        item.preview.toLowerCase().includes(normalizedQuery);
    }
    return true;
  }).sort((a, b) => Number(b.is_pinned) - Number(a.is_pinned) || b.timestamp - a.timestamp);
}

export function shouldUseHistoryShortcut(
  event: Pick<KeyboardEvent, "isComposing" | "keyCode" | "ctrlKey" | "altKey" | "metaKey" | "shiftKey" | "defaultPrevented">,
  inOtherControl: boolean,
): boolean {
  return !event.isComposing && event.keyCode !== 229 && !event.defaultPrevented &&
    !event.ctrlKey && !event.altKey && !event.metaKey && !event.shiftKey && !inOtherControl;
}
