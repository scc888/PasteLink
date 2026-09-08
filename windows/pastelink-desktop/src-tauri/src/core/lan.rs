use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UdpSocket};
use tauri::{AppHandle, Emitter};
use crate::core::state::AppState;
use crate::core::protocol::ClipboardPayload;
use crate::core::crypto::CryptoEngine;

pub struct LanServer;

impl LanServer {
    /// 获取本机首选局域网 IPv4 地址 (支持外网直连推导与离线局域网网络适配器解析)
    pub fn get_local_ip() -> Option<String> {
        // 1. 优先通过 UDP 路由快速探测 (覆盖常见国内国外公共 DNS)
        let probe_addrs = ["8.8.8.8:80", "114.114.114.114:80", "1.1.1.1:80"];
        for target in probe_addrs {
            if let Ok(s) = std::net::UdpSocket::bind("0.0.0.0:0") {
                if s.connect(target).is_ok() {
                    if let Ok(local_addr) = s.local_addr() {
                        let ip = local_addr.ip();
                        if let std::net::IpAddr::V4(v4) = ip {
                            if !v4.is_loopback() && !v4.is_link_local() {
                                return Some(v4.to_string());
                            }
                        }
                    }
                }
            }
        }

        // 2. 离线/纯内网兜底：通过计算机名解析已绑定的私有局域网网卡 IP
        use std::net::ToSocketAddrs;
        if let Ok(hostname) = std::env::var("COMPUTERNAME") {
            if let Ok(addrs) = format!("{}:0", hostname).to_socket_addrs() {
                for addr in addrs {
                    if let std::net::SocketAddr::V4(v4) = addr {
                        let ip = v4.ip();
                        let octets = ip.octets();
                        let is_private = (octets[0] == 10)
                            || (octets[0] == 172 && (16..=31).contains(&octets[1]))
                            || (octets[0] == 192 && octets[1] == 168);
                        if is_private && !ip.is_loopback() && !ip.is_link_local() {
                            return Some(ip.to_string());
                        }
                    }
                }
            }
        }

        None
    }

    /// 启动局域网极速直连服务器 (HTTP REST API + UDP 自动发现)
    pub fn start(
        app_handle: AppHandle,
        state: AppState,
        on_receive_tx: std::sync::mpsc::Sender<ClipboardPayload>,
    ) {
        let tcp_port: u16 = 52089;
        let udp_port: u16 = 52088;

        std::thread::Builder::new()
            .name("pastelink-lan-server".into())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(e) => {
                        log::error!("[LAN] 创建 Tokio Runtime 失败: {}", e);
                        return;
                    }
                };

                rt.block_on(async move {
                    // 1. 启动 UDP 局域网广播自动发现监听 (支持电脑无蓝牙模式)
                    tokio::spawn(async move {
                        let socket = match UdpSocket::bind(format!("0.0.0.0:{}", udp_port)).await {
                            Ok(s) => {
                                s.set_broadcast(true).unwrap_or(());
                                log::info!("[LAN 📡] UDP 服务发现就绪 (监听端口: {})", udp_port);
                                s
                            }
                            Err(e) => {
                                log::warn!("[LAN] UDP 端口 {} 绑定失败: {}", udp_port, e);
                                return;
                            }
                        };

                        let mut buf = [0u8; 1024];
                        loop {
                            if let Ok((len, peer)) = socket.recv_from(&mut buf).await {
                                let msg = String::from_utf8_lossy(&buf[..len]);
                                if msg.starts_with("PASTELINK_DISCOVER") {
                                    let local_ip = Self::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string());
                                    let response = format!(
                                        "PASTELINK_OFFER:{{\"ip\":\"{}\",\"port\":{},\"name\":\"Windows 电脑\"}}",
                                        local_ip, tcp_port
                                    );
                                    let _ = socket.send_to(response.as_bytes(), peer).await;
                                    log::info!("[LAN 📡] 响应来自 {} 的局域网发现广播", peer);
                                }
                            }
                        }
                    });

                    // 2. 启动 TCP 局域网极速直传 HTTP 服务
                    let rx_channel = Arc::new(on_receive_tx);
                    let listener = match TcpListener::bind(format!("0.0.0.0:{}", tcp_port)).await {
                        Ok(l) => {
                            log::info!("[LAN ⚡] TCP 极速直连服务就绪 (监听端口: {})", tcp_port);
                            l
                        }
                        Err(e) => {
                            log::error!("[LAN] TCP 端口 {} 绑定失败: {}", tcp_port, e);
                            return;
                        }
                    };

                    loop {
                        match listener.accept().await {
                            Ok((mut stream, peer)) => {
                                let state = state.clone();
                                let app = app_handle.clone();
                                let rx = rx_channel.clone();

                                tokio::spawn(async move {
                                    if let Err(e) = Self::handle_client(&mut stream, peer, state, app, rx).await {
                                        log::debug!("[LAN] 客户端处理完成: {}", e);
                                    }
                                });
                            }
                            Err(e) => {
                                log::warn!("[LAN] 接受 TCP 连接失败: {}", e);
                                tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
                            }
                        }
                    }
                });
            })
            .expect("Failed to spawn LanServer thread");
    }

    /// 处理 HTTP 客户端连接 (纯异步零框架，极致轻量与高安全性)
    async fn handle_client(
        stream: &mut tokio::net::TcpStream,
        _peer: std::net::SocketAddr,
        state: AppState,
        app_handle: AppHandle,
        rx_channel: Arc<std::sync::mpsc::Sender<ClipboardPayload>>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // 读取 HTTP 请求头部
        let mut buffer = Vec::with_capacity(4096);
        let mut temp_buf = [0u8; 2048];
        let mut header_end = None;

        while header_end.is_none() {
            let n = stream.read(&mut temp_buf).await?;
            if n == 0 {
                return Ok(());
            }
            buffer.extend_from_slice(&temp_buf[..n]);

            // 查找 \r\n\r\n
            if let Some(pos) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                header_end = Some(pos + 4);
                break;
            }
            if buffer.len() > 16384 {
                // 防止恶意超大头部攻击
                return Ok(());
            }
        }

        let header_pos = header_end.unwrap();
        let header_str = String::from_utf8_lossy(&buffer[..header_pos]);
        let mut lines = header_str.lines();
        let request_line = lines.next().unwrap_or("");
        let mut parts = request_line.split_whitespace();
        let method = parts.next().unwrap_or("");
        let path = parts.next().unwrap_or("");

        // CORS 预检请求直接放行
        if method == "OPTIONS" {
            let resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\nContent-Length: 0\r\n\r\n";
            stream.write_all(resp.as_bytes()).await?;
            return Ok(());
        }

        // 解析 Content-Length
        let mut content_length: usize = 0;
        for line in lines {
            if line.to_lowercase().starts_with("content-length:") {
                if let Some(val) = line.split(':').nth(1) {
                    content_length = val.trim().parse::<usize>().unwrap_or(0);
                }
            }
        }

        // 1. 探活握手接口: GET /api/ping
        if method == "GET" && path == "/api/ping" {
            let local_ip = Self::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string());
            let body = format!("{{\"status\":\"ok\",\"device_name\":\"Windows 电脑\",\"ip\":\"{}\"}}", local_ip);
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n{}",
                body.len(),
                body
            );
            stream.write_all(resp.as_bytes()).await?;
            return Ok(());
        }

        // 2. 获取最新剪贴板载荷: GET /api/clipboard/latest (供 iPhone 局域网极速拉取)
        if method == "GET" && path == "/api/clipboard/latest" {
            if let Some(payload_bytes) = state.get_latest_payload() {
                // 标记已通过局域网拉取
                state.mark_payload_fetched_over_lan();
                let resp_head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n",
                    payload_bytes.len()
                );
                stream.write_all(resp_head.as_bytes()).await?;
                stream.write_all(&payload_bytes).await?;
                log::info!("[LAN ⚡ → iPhone] iPhone 已通过局域网高速下载最新剪贴板 ({} 字节)", payload_bytes.len());
                return Ok(());
            } else {
                let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                stream.write_all(resp.as_bytes()).await?;
                return Ok(());
            }
        }

        // 3. 接收 iPhone 剪贴板推送: POST /api/clipboard (包含图片或文本的 AES-256-GCM 密文)
        if method == "POST" && path == "/api/clipboard" {
            if content_length == 0 || content_length > 15 * 1024 * 1024 {
                let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
                stream.write_all(resp.as_bytes()).await?;
                return Ok(());
            }

            // 读取完整的 POST 请求体密文
            let mut body_bytes = buffer[header_pos..].to_vec();
            while body_bytes.len() < content_length {
                let n = stream.read(&mut temp_buf).await?;
                if n == 0 {
                    break;
                }
                body_bytes.extend_from_slice(&temp_buf[..n]);
            }

            if body_bytes.len() != content_length {
                let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
                stream.write_all(resp.as_bytes()).await?;
                return Ok(());
            }

            // 零信任认证与解密：使用配对 PIN 码解密 AES-256-GCM
            let pin = state.pairing_code.lock().unwrap().clone();
            let key = CryptoEngine::derive_key(&pin);

            match CryptoEngine::decrypt_raw(&body_bytes, &key) {
                Ok(raw_bytes) => {
                    if let Some((width, height, png_bytes)) = crate::core::protocol::unwrap_image_payload(&raw_bytes) {
                        log::info!("[LAN ⚡ ← iPhone] 收到局域网高速推送无损图片 ({}×{}, {} 字节)", width, height, png_bytes.len());
                        let _ = rx_channel.send(ClipboardPayload::Image {
                            width,
                            height,
                            png_bytes: png_bytes.to_vec(),
                        });
                    } else if let Ok(text) = String::from_utf8(raw_bytes) {
                        log::info!("[LAN ⚡ ← iPhone] 收到局域网高速推送文本 ({} 字符)", text.chars().count());
                        let _ = rx_channel.send(ClipboardPayload::Text(text));
                    }

                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 19\r\n\r\n{\"status\":\"success\"}";
                    stream.write_all(resp.as_bytes()).await?;
                    let _ = app_handle.emit("lan-sync-success", ());
                    return Ok(());
                }
                Err(_) => {
                    log::warn!("[LAN ⚠️] 局域网请求密文解密失败 (PIN 码不匹配)");
                    let resp = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"error\":\"unauthorized\"}";
                    stream.write_all(resp.as_bytes()).await?;
                    return Ok(());
                }
            }
        }

        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        stream.write_all(resp.as_bytes()).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lan_get_local_ip() {
        if let Some(ip) = LanServer::get_local_ip() {
            assert!(!ip.is_empty());
            assert!(ip.contains('.'));
        }
    }

    #[test]
    fn test_lan_encrypted_payload_roundtrip() {
        let pin = "123456";
        let key = CryptoEngine::derive_key(pin);

        // 模拟 iPhone 通过局域网 POST 推送无损图片
        let fake_png = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4];
        let wrapped = crate::core::protocol::wrap_image_payload(&fake_png, 800, 600);
        let encrypted = CryptoEngine::encrypt_raw(&wrapped, &key).expect("encryption failed");

        // 模拟 Windows 端 LAN 接收并解密
        let decrypted = CryptoEngine::decrypt_raw(&encrypted, &key).expect("decryption failed");
        let (w, h, png) = crate::core::protocol::unwrap_image_payload(&decrypted).expect("unwrap failed");

        assert_eq!(w, 800);
        assert_eq!(h, 600);
        assert_eq!(png, fake_png.as_slice());
    }
}
