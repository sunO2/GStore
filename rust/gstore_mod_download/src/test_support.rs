//! 测试支撑：本地 HTTP 服务（支持 Range）与临时目录。
//!
//! 引擎与调度器的测试都需要"一个真的会返回 206 的服务器"，
//! 抽到这里避免两份实现漂移（repo 模块的测试也是同套路）。

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;

/// 起一个支持 Range 的本地 HTTP 服务，返回 URL。
/// `etag` 可控，便于测"服务端文件变更"分支。
pub fn spawn_range_server(body: Vec<u8>, etag: &'static str) -> String {
    spawn_range_server_with(body, etag, None)
}

/// `fail_first_n`：前 N 个请求返回 500（测重试退避）。
pub fn spawn_range_server_with(
    body: Vec<u8>,
    etag: &'static str,
    fail_first_n: Option<usize>,
) -> String {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let served = Arc::new(AtomicUsize::new(0));

    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut sock) = stream else { continue };
            let body = body.clone();
            let served = served.clone();
            std::thread::spawn(move || {
                let mut buf = [0u8; 8192];
                let n = sock.read(&mut buf).unwrap_or(0);
                if n == 0 {
                    return;
                }
                let req = String::from_utf8_lossy(&buf[..n]).to_string();

                if let Some(limit) = fail_first_n {
                    let k = served.fetch_add(1, Ordering::SeqCst);
                    if k < limit {
                        let _ = sock.write_all(
                            b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                }

                let range = req.lines().find_map(|l| {
                    let l = l.to_ascii_lowercase();
                    l.strip_prefix("range: bytes=").map(|v| v.trim().to_string())
                });

                match range {
                    Some(r) => {
                        let (a, b) = r.split_once('-').unwrap_or(("0", ""));
                        let start: usize = a.parse().unwrap_or(0);
                        let end: usize = if b.is_empty() {
                            body.len().saturating_sub(1)
                        } else {
                            b.parse().unwrap_or(body.len().saturating_sub(1))
                        };
                        let end = end.min(body.len().saturating_sub(1));
                        if start > end || start >= body.len() {
                            let _ = sock.write_all(
                                b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                            );
                            return;
                        }
                        let slice = &body[start..=end];
                        let head = format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nAccept-Ranges: bytes\r\nETag: {}\r\nConnection: close\r\n\r\n",
                            slice.len(), start, end, body.len(), etag
                        );
                        let _ = sock.write_all(head.as_bytes());
                        let _ = sock.write_all(slice);
                    }
                    None => {
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nETag: {}\r\nConnection: close\r\n\r\n",
                            body.len(), etag
                        );
                        let _ = sock.write_all(head.as_bytes());
                        let _ = sock.write_all(&body);
                    }
                }
            });
        }
    });

    format!("http://{addr}/file.bin")
}

/// 带响应延迟的服务器：让"任务在跑"变成可观测的稳定状态（测并发/队列/暂停必备）。
pub fn spawn_range_server_delayed(body: Vec<u8>, etag: &'static str, delay_ms: u64) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();

    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut sock) = stream else { continue };
            let body = body.clone();
            std::thread::spawn(move || {
                let mut buf = [0u8; 8192];
                let n = sock.read(&mut buf).unwrap_or(0);
                if n == 0 {
                    return;
                }
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                // 延迟放在读请求之后、写响应之前：任务会稳定停在 "downloading"
                std::thread::sleep(std::time::Duration::from_millis(delay_ms));

                let range = req.lines().find_map(|l| {
                    let l = l.to_ascii_lowercase();
                    l.strip_prefix("range: bytes=").map(|v| v.trim().to_string())
                });
                match range {
                    Some(r) => {
                        let (a, b) = r.split_once('-').unwrap_or(("0", ""));
                        let start: usize = a.parse().unwrap_or(0);
                        let end: usize = if b.is_empty() {
                            body.len().saturating_sub(1)
                        } else {
                            b.parse().unwrap_or(body.len().saturating_sub(1))
                        };
                        let end = end.min(body.len().saturating_sub(1));
                        let slice = &body[start..=end];
                        let head = format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nAccept-Ranges: bytes\r\nETag: {}\r\nConnection: close\r\n\r\n",
                            slice.len(), start, end, body.len(), etag
                        );
                        let _ = sock.write_all(head.as_bytes());
                        let _ = sock.write_all(slice);
                    }
                    None => {
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nETag: {}\r\nConnection: close\r\n\r\n",
                            body.len(), etag
                        );
                        let _ = sock.write_all(head.as_bytes());
                        let _ = sock.write_all(&body);
                    }
                }
            });
        }
    });

    format!("http://{addr}/file.bin")
}

/// 每次调用返回一个全新的临时目录（同一进程内测试并发时不会互相干扰）。
pub fn tmpdir(tag: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let n = SEQ.fetch_add(1, Ordering::SeqCst);
    let p = std::env::temp_dir().join(format!("dl_test_{tag}_{}_{n}", std::process::id()));
    let _ = std::fs::create_dir_all(&p);
    p
}

/// 生成确定性测试数据。
pub fn make_body(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i % 251) as u8).collect()
}

/// 数据的 sha256（与引擎同一算法，用于断言）。
pub fn sha256_of(body: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(body);
    hex::encode(h.finalize())
}
