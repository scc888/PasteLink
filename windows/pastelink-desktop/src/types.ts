export interface ClipboardItem {
  id: string;
  content: string;
  source: 'windows' | 'iphone';
  timestamp: number;
  sha256: string;
  preview: string;
  char_count: number;
  item_type: 'url' | 'code' | 'otp' | 'text';
  is_pinned: boolean;
}

export interface StatusPayload {
  is_paused: boolean;
  ignore_password_manager: boolean;
  autostart_enabled: boolean;
  connected_devices: number;
  pairing_code: string;
  recent_items: ClipboardItem[];
}
