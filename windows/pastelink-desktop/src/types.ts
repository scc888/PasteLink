export interface ClipboardItem {
  id: string;
  content: string;
  source: 'windows' | 'iphone';
  timestamp: number;
  sha256: string;
  preview: string;
  char_count: number;
  item_type: 'url' | 'code' | 'otp' | 'text' | 'image';
  is_pinned: boolean;
  image_data?: string;
  width?: number;
  height?: number;
  file_size?: number;
}

export interface TransferProgressPayload {
  is_active: boolean;
  percent: number;
  total_bytes: number;
  transferred_chunks: number;
  total_chunks: number;
  item_type: 'image' | 'text';
  direction: 'send' | 'receive';
}

export interface StatusPayload {
  is_paused: boolean;
  ignore_password_manager: boolean;
  autostart_enabled: boolean;
  connected_devices: number;
  pairing_code: string;
  recent_items: ClipboardItem[];
}

export type ThemeMode = 'system' | 'light' | 'dark';
