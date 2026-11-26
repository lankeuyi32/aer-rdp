use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ironrdp::pdu::rdp::server_error_info::{ErrorInfo, ProtocolIndependentCode};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, oneshot};

use crate::{ControlCmd, PixelEncoding, RecordedInput, ServerMetricsInner};

const MAX_HTTP_HEADER_BYTES: usize = 65_536;
const MAX_HTTP_BODY_BYTES: usize = 65_536;
const HTTP_READ_TIMEOUT: Duration = Duration::from_secs(5);

pub async fn run_http_server(
    listener: TcpListener,
    rdp_port: u16,
    cert_sha256: String,
    metrics: Arc<Mutex<ServerMetricsInner>>,
    recorded_inputs: Arc<Mutex<Vec<RecordedInput>>>,
    control_tx: broadcast::Sender<ControlCmd>,
    mut shutdown_rx: oneshot::Receiver<()>,
) {
    loop {
        tokio::select! {
            _ = &mut shutdown_rx => break,
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else {
                    break;
                };
                let cert_sha = cert_sha256.clone();
                let metrics = Arc::clone(&metrics);
                let inputs = Arc::clone(&recorded_inputs);
                let tx = control_tx.clone();
                tokio::spawn(async move {
                    let _ = handle_http_conn(stream, rdp_port, cert_sha, metrics, inputs, tx).await;
                });
            }
        }
    }
}

pub fn bind_http_listener(addr: SocketAddr) -> std::io::Result<std::net::TcpListener> {
    let listener = std::net::TcpListener::bind(addr)?;
    listener.set_nonblocking(true)?;
    Ok(listener)
}

enum HeaderReadOutcome {
    Found(usize),
    Eof,
    TooLarge,
    Timeout,
}

async fn read_http_headers(
    stream: &mut TcpStream,
    buf: &mut Vec<u8>,
    read_timeout: Duration,
) -> std::io::Result<HeaderReadOutcome> {
    let mut tmp = [0u8; 2048];
    let deadline = tokio::time::Instant::now() + read_timeout;
    let res = tokio::time::timeout_at(deadline, async {
        loop {
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                return Ok::<HeaderReadOutcome, std::io::Error>(HeaderReadOutcome::Eof);
            }
            buf.extend_from_slice(&tmp[..n]);
            if let Some(pos) = find_double_crlf(buf) {
                return Ok(HeaderReadOutcome::Found(pos));
            }
            if buf.len() > MAX_HTTP_HEADER_BYTES {
                return Ok(HeaderReadOutcome::TooLarge);
            }
        }
    })
    .await;

    match res {
        Ok(inner) => inner,
        Err(_) => Ok(HeaderReadOutcome::Timeout),
    }
}

async fn handle_http_conn(
    mut stream: TcpStream,
    rdp_port: u16,
    cert_sha256: String,
    metrics: Arc<Mutex<ServerMetricsInner>>,
    recorded_inputs: Arc<Mutex<Vec<RecordedInput>>>,
    control_tx: broadcast::Sender<ControlCmd>,
) -> anyhow::Result<()> {
    let mut buf = Vec::with_capacity(4096);
    let header_end = match read_http_headers(&mut stream, &mut buf, HTTP_READ_TIMEOUT).await? {
        HeaderReadOutcome::Found(pos) => pos,
        HeaderReadOutcome::Eof => return Ok(()),
        HeaderReadOutcome::TooLarge => {
            send_json_response(
                &mut stream,
                400,
                "Bad Request",
                &json!({ "error": "request too large" }),
            )
            .await?;
            return Ok(());
        }
        HeaderReadOutcome::Timeout => {
            send_json_response(
                &mut stream,
                408,
                "Request Timeout",
                &json!({ "error": "read timeout" }),
            )
            .await?;
            return Ok(());
        }
    };
    let mut tmp = [0u8; 2048];

    let mut headers = [httparse::EMPTY_HEADER; 32];
    let mut req = httparse::Request::new(&mut headers);
    let status = req.parse(&buf[..header_end])?;
    if status.is_partial() {
        send_json_response(
            &mut stream,
            400,
            "Bad Request",
            &json!({ "error": "partial request" }),
        )
        .await?;
        return Ok(());
    }

    let method = req.method.unwrap_or("");
    let path = req.path.unwrap_or("/");
    let content_len: usize = match req
        .headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case("content-length"))
    {
        Some(h) => {
            let Ok(s) = std::str::from_utf8(h.value) else {
                send_json_response(
                    &mut stream,
                    400,
                    "Bad Request",
                    &json!({ "error": "invalid content-length" }),
                )
                .await?;
                return Ok(());
            };
            let Ok(len) = s.trim().parse::<usize>() else {
                send_json_response(
                    &mut stream,
                    400,
                    "Bad Request",
                    &json!({ "error": "invalid content-length" }),
                )
                .await?;
                return Ok(());
            };
            if len > MAX_HTTP_BODY_BYTES {
                send_json_response(
                    &mut stream,
                    413,
                    "Payload Too Large",
                    &json!({ "error": "request body too large" }),
                )
                .await?;
                return Ok(());
            }
            len
        }
        None => 0,
    };

    let mut body = buf[header_end..].to_vec();
    let body_deadline = tokio::time::Instant::now() + HTTP_READ_TIMEOUT;
    let body_res = tokio::time::timeout_at(body_deadline, async {
        while body.len() < content_len {
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                return Ok::<bool, std::io::Error>(false);
            }
            body.extend_from_slice(&tmp[..n]);
        }
        Ok(true)
    })
    .await;
    match body_res {
        Ok(Ok(true)) => {}
        Ok(Ok(false)) => {
            send_json_response(
                &mut stream,
                400,
                "Bad Request",
                &json!({ "error": "incomplete request body" }),
            )
            .await?;
            return Ok(());
        }
        Ok(Err(e)) => return Err(e.into()),
        Err(_) => {
            send_json_response(
                &mut stream,
                408,
                "Request Timeout",
                &json!({ "error": "read timeout" }),
            )
            .await?;
            return Ok(());
        }
    }
    body.truncate(content_len);

    let (code, reason, payload) = route_request(
        method,
        path,
        &body,
        rdp_port,
        &cert_sha256,
        &metrics,
        &recorded_inputs,
        &control_tx,
    )
    .await;

    send_json_response(&mut stream, code, reason, &payload).await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn route_request(
    method: &str,
    path: &str,
    body: &[u8],
    rdp_port: u16,
    cert_sha256: &str,
    metrics: &Arc<Mutex<ServerMetricsInner>>,
    recorded_inputs: &Arc<Mutex<Vec<RecordedInput>>>,
    control_tx: &broadcast::Sender<ControlCmd>,
) -> (u16, &'static str, serde_json::Value) {
    match (method, path) {
        ("GET", "/health") => (
            200,
            "OK",
            json!({
                "ok": true,
                "rdpPort": rdp_port,
                "certSha256": cert_sha256,
            }),
        ),
        ("GET", "/metrics") => {
            let m = metrics.lock().expect("metrics lock").clone();
            (200, "OK", serde_json::to_value(m).unwrap_or_else(|_| json!({})))
        }
        ("GET", "/inputs") => {
            let evs = recorded_inputs.lock().expect("inputs lock").clone();
            (200, "OK", json!({ "events": evs }))
        }
        ("POST", "/control/deactivate") => {
            let new_size = if body.iter().all(|b| b.is_ascii_whitespace()) {
                None
            } else {
                let parsed: serde_json::Value = match serde_json::from_slice(body) {
                    Ok(v) => v,
                    Err(_) => {
                        return (400, "Bad Request", json!({ "error": "invalid json body" }));
                    }
                };
                let Some(obj) = parsed.as_object() else {
                    return (
                        400,
                        "Bad Request",
                        json!({ "error": "invalid json body: expected object" }),
                    );
                };
                let has_w = obj.contains_key("width");
                let has_h = obj.contains_key("height");
                if !has_w && !has_h {
                    None
                } else if has_w && has_h {
                    let w = obj
                        .get("width")
                        .and_then(|v| v.as_u64())
                        .and_then(|n| u16::try_from(n).ok())
                        .filter(|&n| n >= 1);
                    let h = obj
                        .get("height")
                        .and_then(|v| v.as_u64())
                        .and_then(|n| u16::try_from(n).ok())
                        .filter(|&n| n >= 1);
                    match (w, h) {
                        (Some(w), Some(h)) => Some((w, h)),
                        _ => {
                            return (
                                400,
                                "Bad Request",
                                json!({ "error": "invalid width/height: expected integers in 1..=65535" }),
                            );
                        }
                    }
                } else {
                    return (
                        400,
                        "Bad Request",
                        json!({ "error": "invalid width/height: expected integers in 1..=65535" }),
                    );
                }
            };
            let (ack_tx, ack_rx) = oneshot::channel();
            let _ = control_tx.send(ControlCmd::DeactivateAll {
                new_size,
                ack: Some(Arc::new(Mutex::new(Some(ack_tx)))),
            });
            let _ = tokio::time::timeout(std::time::Duration::from_secs(2), ack_rx).await;
            (200, "OK", json!({ "ok": true }))
        }
        ("POST", "/control/disconnect") => {
            let _ = control_tx.send(ControlCmd::Disconnect {
                error_info: ErrorInfo::ProtocolIndependentCode(
                    ProtocolIndependentCode::RpcInitiatedDisconnect,
                ),
            });
            (200, "OK", json!({ "ok": true }))
        }
        ("POST", "/control/frame") => {
            let (ack_tx, ack_rx) = oneshot::channel();
            let _ = control_tx.send(ControlCmd::Frame {
                encoding_override: None::<PixelEncoding>,
                ack: Some(Arc::new(Mutex::new(Some(ack_tx)))),
            });
            let frames_sent = tokio::time::timeout(std::time::Duration::from_secs(2), ack_rx)
                .await
                .ok()
                .and_then(|r| r.ok())
                .unwrap_or_else(|| metrics.lock().expect("metrics lock").frames_sent);
            (200, "OK", json!({ "ok": true, "framesSent": frames_sent }))
        }
        _ => (404, "Not Found", json!({ "error": "not found", "path": path })),
    }
}

fn find_double_crlf(buf: &[u8]) -> Option<usize> {
    buf.windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|pos| pos + 4)
}

async fn send_json_response(
    stream: &mut TcpStream,
    code: u16,
    reason: &str,
    payload: &serde_json::Value,
) -> std::io::Result<()> {
    let body = serde_json::to_vec(payload).unwrap_or_else(|_| b"{}".to_vec());
    let header = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(&body).await?;
    stream.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn spawn_test_http_server() -> (
        u16,
        Arc<Mutex<ServerMetricsInner>>,
        broadcast::Receiver<ControlCmd>,
        oneshot::Sender<()>,
    ) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let metrics = Arc::new(Mutex::new(ServerMetricsInner::default()));
        let inputs = Arc::new(Mutex::new(Vec::new()));
        let (control_tx, control_rx) = broadcast::channel(16);
        let (sd_tx, sd_rx) = oneshot::channel();
        tokio::spawn(run_http_server(
            listener,
            3389,
            "00".repeat(32),
            Arc::clone(&metrics),
            inputs,
            control_tx,
            sd_rx,
        ));
        (port, metrics, control_rx, sd_tx)
    }

    async fn send_raw_http(port: u16, raw: &[u8]) -> (u16, String) {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        stream.write_all(raw).await.unwrap();
        let mut resp = Vec::new();
        stream.read_to_end(&mut resp).await.unwrap();
        let text = String::from_utf8(resp).unwrap();
        let (head, body) = text.split_once("\r\n\r\n").unwrap();
        let status_code: u16 = head
            .lines()
            .next()
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .parse()
            .unwrap();
        (status_code, body.to_owned())
    }

    #[tokio::test]
    async fn deactivate_rejects_invalid_resize_and_allows_empty_or_valid() {
        let (port, _metrics, mut rx, sd) = spawn_test_http_server().await;

        for bad_body in [
            r#"{"width":0,"height":0}"#,
            r#"{"width":70000,"height":720}"#,
            r#"{"width":1024}"#,
            r#"{"height":768}"#,
            r#"{not-json"#,
            r#"[1,2]"#,
        ] {
            let req = format!(
                "POST /control/deactivate HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{bad_body}",
                bad_body.len()
            );
            let (status, _) = send_raw_http(port, req.as_bytes()).await;
            assert_eq!(status, 400, "expected 400 for body {bad_body}");
            assert!(rx.try_recv().is_err(), "bad body {bad_body} must not emit DeactivateAll");
        }

        // Valid empty "{}" preserves same-size deactivation
        let empty_req = "POST /control/deactivate HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";
        let (status, _) = send_raw_http(port, empty_req.as_bytes()).await;
        assert_eq!(status, 200);
        assert!(matches!(
            rx.try_recv().unwrap(),
            ControlCmd::DeactivateAll { new_size: None, .. }
        ));

        // Valid explicit resize
        let resize_body = r#"{"width":1024,"height":768}"#;
        let resize_req = format!(
            "POST /control/deactivate HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{resize_body}",
            resize_body.len()
        );
        let (status, _) = send_raw_http(port, resize_req.as_bytes()).await;
        assert_eq!(status, 200);
        assert!(matches!(
            rx.try_recv().unwrap(),
            ControlCmd::DeactivateAll {
                new_size: Some((1024, 768)),
                ..
            }
        ));

        let _ = sd.send(());
    }

    #[tokio::test]
    async fn http_rejects_oversized_and_malformed_content_length() {
        let (port, _metrics, mut rx, sd) = spawn_test_http_server().await;

        let oversized = "POST /control/deactivate HTTP/1.1\r\nHost: localhost\r\nContent-Length: 99999999\r\nConnection: close\r\n\r\n{}";
        let (status, _) = send_raw_http(port, oversized.as_bytes()).await;
        assert_eq!(status, 413);
        assert!(rx.try_recv().is_err());

        let malformed_len = "POST /control/deactivate HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\nConnection: close\r\n\r\n{}";
        let (status, _) = send_raw_http(port, malformed_len.as_bytes()).await;
        assert_eq!(status, 400);
        assert!(rx.try_recv().is_err());

        let _ = sd.send(());
    }

    #[tokio::test]
    async fn slowloris_1byte_drip_hits_total_header_deadline() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let deadline = Duration::from_millis(120);

        let server_task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buf = Vec::with_capacity(256);
            let started = tokio::time::Instant::now();
            let outcome = read_http_headers(&mut stream, &mut buf, deadline).await.unwrap();
            let elapsed = started.elapsed();
            if matches!(outcome, HeaderReadOutcome::Timeout) {
                let _ = send_json_response(
                    &mut stream,
                    408,
                    "Request Timeout",
                    &json!({ "error": "read timeout" }),
                )
                .await;
            }
            (matches!(outcome, HeaderReadOutcome::Timeout), elapsed)
        });

        let mut client = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let _ = client.set_nodelay(true);
        let drip = b"GET /health HTTP/1.1\r\nHost: localhost\r\n";
        for byte in drip.iter().take(10) {
            if client.write_all(&[*byte]).await.is_err() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(40)).await;
        }

        let (timed_out, elapsed) = server_task.await.unwrap();
        assert!(timed_out, "expected total header deadline Timeout");
        assert!(
            elapsed >= Duration::from_millis(100) && elapsed < Duration::from_millis(350),
            "unexpected deadline elapsed: {elapsed:?}"
        );

        let mut resp = Vec::new();
        let _ = client.read_to_end(&mut resp).await;
        let text = String::from_utf8_lossy(&resp);
        assert!(text.starts_with("HTTP/1.1 408 Request Timeout"), "got: {text}");
    }
}
