//! Fetch integration tests against loopback fixture HTTP servers.
//!
//! `allow_private_targets` is enabled because the fixture servers bind
//! `127.0.0.1`; production traffic goes through [`fetch_and_parse`] with the
//! SSRF guard on (see `tests`).

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use super::fetch::{fetch_and_parse, FetchOptions};
use super::{ERR_FETCH_FAILED, ERR_PARSE_FAILED, ERR_TOO_LARGE, MAX_BODY_BYTES};

const MINI_CLASH: &str = r#"
proxies:
  - {name: "n1", type: ss, server: 1.2.3.4, port: 8388, cipher: aes-256-gcm, password: pw}
  - {name: "n2", type: trojan, server: 1.2.3.5, port: 443, password: pw}
"#;

fn http_bytes(status: u16, headers: &[(&str, &str)], body: &[u8]) -> Vec<u8> {
    let mut head = format!("HTTP/1.1 {status} OK\r\n");
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
    let mut bytes = head.into_bytes();
    bytes.extend_from_slice(body);
    bytes
}

fn read_request(stream: &mut TcpStream) -> Vec<u8> {
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        match stream.read(&mut byte) {
            Ok(0) | Err(_) => break,
            Ok(_) => buf.push(byte[0]),
        }
    }
    buf
}

fn serve_n(response: Vec<u8>, n: usize) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = std::thread::spawn(move || {
        for _ in 0..n {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let _ = read_request(&mut stream);
                    let _ = stream.write_all(&response);
                    let _ = stream.shutdown(Shutdown::Both);
                }
                Err(_) => break,
            }
        }
    });
    (format!("http://{addr}/sub"), handle)
}

fn serve_by_user_agent(matchers: Vec<(&'static str, Vec<u8>)>) -> (String, Arc<Mutex<Vec<String>>>, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let seen_writer = seen.clone();
    let count = matchers.len();
    let handle = std::thread::spawn(move || {
        for _ in 0..count {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };
            let request = read_request(&mut stream);
            let text = String::from_utf8_lossy(&request);
            let user_agent = text
                .lines()
                .find(|line| line.to_ascii_lowercase().starts_with("user-agent:"))
                .map(|line| line["user-agent:".len()..].trim().to_string())
                .unwrap_or_default();
            seen_writer.lock().unwrap_or_else(|e| e.into_inner()).push(user_agent.clone());
            let response = matchers
                .iter()
                .find(|(needle, _)| user_agent.contains(needle))
                .map(|(_, body)| body.clone())
                .unwrap_or_else(|| http_bytes(404, &[], b"nope"));
            let _ = stream.write_all(&response);
            let _ = stream.shutdown(Shutdown::Both);
        }
    });
    (format!("http://{addr}/sub"), seen, handle)
}

fn serve_oversize(content_length: usize) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = std::thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let _ = read_request(&mut stream);
            let header = format!("HTTP/1.1 200 OK\r\nContent-Length: {content_length}\r\n\r\n");
            if stream.write_all(header.as_bytes()).is_err() {
                return;
            }
            let chunk = vec![b'x'; 64 * 1024];
            let mut written = 0usize;
            while written < content_length {
                let take = chunk.len().min(content_length - written);
                if stream.write_all(&chunk[..take]).is_err() {
                    break;
                }
                written += take;
            }
            let _ = stream.shutdown(Shutdown::Both);
        }
    });
    (format!("http://{addr}/sub"), handle)
}

fn opts(user_agents: Vec<String>) -> FetchOptions {
    FetchOptions {
        allow_private_targets: true,
        max_bytes: MAX_BODY_BYTES,
        user_agents,
    }
}

fn run(url: &str, agents: Vec<String>) -> Result<super::ImportedProfile, gstore_contract::error::ModuleError> {
    super::sub_runtime()
        .unwrap()
        .block_on(fetch_and_parse(url, None, &opts(agents)))
}

#[test]
fn imports_clash_with_userinfo_and_content_disposition() {
    let response = http_bytes(
        200,
        &[
            (
                "Subscription-Userinfo",
                "upload=100; download=200; total=1000; expire=1700000000",
            ),
            ("Content-Disposition", "attachment; filename=\"My Sub.yaml\""),
            ("Content-Type", "text/yaml"),
        ],
        MINI_CLASH.as_bytes(),
    );
    let (url, handle) = serve_n(response, 1);
    let profile = run(&url, vec!["clash.meta/1.19.0".into()]).unwrap();
    handle.join().unwrap();

    assert_eq!(profile.format, "clash");
    assert_eq!(profile.node_count, 2);
    assert_eq!(profile.name, "My Sub");
    let info = profile.userinfo.expect("userinfo parsed");
    assert_eq!(info.total, Some(1000));
    assert_eq!(info.upload, Some(100));
    assert_eq!(info.expire, Some(1700000000));
    assert_eq!(profile.source.filename.as_deref(), Some("My Sub.yaml"));
    assert_eq!(profile.source.url.as_deref(), Some(url.as_str()));
}

#[test]
fn multi_user_agent_retry_uses_the_next_agent() {
    let first = http_bytes(200, &[("Content-Type", "text/html")], b"<html>blocked</html>");
    let second = http_bytes(200, &[("Content-Type", "text/yaml")], MINI_CLASH.as_bytes());
    let (url, seen, handle) = serve_by_user_agent(vec![
        ("clash.meta", first),
        ("mihomo", second),
    ]);
    let profile = run(
        &url,
        vec!["clash.meta/1.19.0".into(), "mihomo/1.19.0".into()],
    )
    .unwrap();
    handle.join().unwrap();

    assert_eq!(profile.node_count, 2);
    let seen = seen.lock().unwrap_or_else(|e| e.into_inner());
    assert_eq!(seen.len(), 2, "exactly two attempts: {seen:?}");
    assert!(seen[0].contains("clash.meta"));
    assert!(seen[1].contains("mihomo"));
}

#[test]
fn oversized_streaming_body_is_capped_without_buffering_it_all() {
    let (url, handle) = serve_oversize(50 * 1024 * 1024);
    let err = run(&url, vec!["clash.meta/1.19.0".into()]).unwrap_err();
    let _ = handle.join();
    assert_eq!(err.code, ERR_TOO_LARGE);
    assert_eq!(
        err.status,
        gstore_contract::error::StatusCode::ResourceExhausted
    );
}

#[test]
fn gzip_encoded_body_is_rejected_not_decompressed() {
    let gzip_bomb = http_bytes(
        200,
        &[("Content-Encoding", "gzip")],
        &[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03],
    );
    let (url, handle) = serve_n(gzip_bomb, 1);
    let err = run(&url, vec!["clash.meta/1.19.0".into()]).unwrap_err();
    handle.join().unwrap();
    assert_eq!(err.code, ERR_FETCH_FAILED);
}

#[test]
fn malformed_yaml_over_http_is_a_parse_error() {
    let response = http_bytes(200, &[], b"proxies: [this is : not : valid");
    let (url, handle) = serve_n(response, 1);
    let err = run(&url, vec!["clash.meta/1.19.0".into()]).unwrap_err();
    handle.join().unwrap();
    assert_eq!(err.code, ERR_PARSE_FAILED);
}

#[test]
fn chunked_clash_body_is_decoded() {
    let body = MINI_CLASH.as_bytes();
    let mut response = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec();
    response.extend_from_slice(format!("{:x}\r\n", body.len()).as_bytes());
    response.extend_from_slice(body);
    response.extend_from_slice(b"\r\n0\r\n\r\n");
    let (url, handle) = serve_n(response, 1);
    let profile = run(&url, vec!["clash.meta/1.19.0".into()]).unwrap();
    handle.join().unwrap();
    assert_eq!(profile.node_count, 2);
}
