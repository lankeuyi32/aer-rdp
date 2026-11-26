use std::path::PathBuf;
use std::process::Command;

use rdp_test_server::{AuthMode, MockConfig, MockRdpServer};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

async fn http_call(port: u16, method: &str, path: &str, body: Option<&str>) -> serde_json::Value {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let payload = body.unwrap_or("");
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    );
    stream.write_all(req.as_bytes()).await.unwrap();
    let mut resp = Vec::new();
    stream.read_to_end(&mut resp).await.unwrap();
    let raw = String::from_utf8(resp).unwrap();
    let (_, json_body) = raw.split_once("\r\n\r\n").expect("HTTP response body");
    serde_json::from_str(json_body).expect("valid JSON HTTP response")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t17_aer_rdp_cli_json_smoke_and_http_control() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Nla,
        username: "testuser".to_owned(),
        password: "testpass".to_owned(),
        audio_hz: 440,
        auto_audio_interval_ms: Some(20),
        rdpsnd_version: 8,
        control_http_addr: Some(([127, 0, 0, 1], 0).into()),
        ..Default::default()
    })
    .await
    .unwrap();

    let http_port = server.http_port.expect("http_port");

    // 1. Check GET /health
    let health = http_call(http_port, "GET", "/health", None).await;
    assert_eq!(health["ok"], true);
    assert_eq!(health["rdpPort"], server.port());
    assert_eq!(health["certSha256"], server.cert_sha256());

    let tmp_dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let script_path = tmp_dir.join("cli_smoke_actions.json");
    let report_path = tmp_dir.join("cli_smoke_report.json");

    let actions = serde_json::json!([
        { "type": "wait_active", "timeout_ms": 5000 },
        { "type": "wait_audio_ready", "min_queued_ms": 50, "timeout_ms": 5000 },
        { "type": "drain_audio", "ms": 300 },
        { "type": "wait_frames", "min_frames": 1, "timeout_ms": 5000 },
        { "type": "pointer", "x": 200, "y": 250, "button_mask": 1, "down": true, "wheel_delta": 0 },
        { "type": "pointer", "x": 200, "y": 250, "button_mask": 1, "down": false, "wheel_delta": 0 },
        { "type": "scancode", "code": 30, "extended": false, "down": true },
        { "type": "scancode", "code": 30, "extended": false, "down": false },
        { "type": "unicode", "code_unit": 65, "down": true },
        { "type": "unicode", "code_unit": 65, "down": false },
        { "type": "set_volume", "volume": 0.8 },
        { "type": "set_mute", "muted": false },
        { "type": "wait_ms", "ms": 150 },
        { "type": "disconnect" }
    ]);
    std::fs::write(&script_path, serde_json::to_vec_pretty(&actions).unwrap()).unwrap();

    let cli_bin = env!("CARGO_BIN_EXE_aer-rdp-cli");
    let rdp_port = server.port();
    let cert_pin = format!("sha256:{}", server.cert_sha256());
    let script_arg = script_path.clone();
    let report_arg = report_path.clone();

    let cli_handle = tokio::task::spawn_blocking(move || {
        Command::new(cli_bin)
            .args([
                "--host",
                "127.0.0.1",
                "--port",
                &rdp_port.to_string(),
                "--auth",
                "nla",
                "--user",
                "testuser",
                "--pass",
                "testpass",
                "--width",
                "1280",
                "--height",
                "720",
                "--audio",
                "local",
                "--trust-cert",
                &cert_pin,
                "--script",
                script_arg.to_str().unwrap(),
                "--out",
                report_arg.to_str().unwrap(),
            ])
            .output()
            .expect("spawn aer-rdp-cli")
    });

    // While CLI is active, exercise POST /control/frame and check metrics
    for _ in 0..40 {
        let m = http_call(http_port, "GET", "/metrics", None).await;
        if m["activeSessions"].as_u64().unwrap_or(0) > 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    let frame_resp = http_call(http_port, "POST", "/control/frame", None).await;
    assert_eq!(frame_resp["ok"], true);

    let output = cli_handle.await.unwrap();
    assert!(
        output.status.success(),
        "aer-rdp-cli failed (status={:?}): stdout={}, stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let report_raw = std::fs::read_to_string(&report_path).unwrap();
    let report: serde_json::Value = serde_json::from_str(&report_raw).unwrap();
    assert_eq!(report["connected"], true, "report: {report_raw}");
    assert_eq!(report["finalState"], "Disconnected", "report: {report_raw}");
    assert!(
        report["framesReceived"].as_u64().unwrap() >= 2,
        "report: {report_raw}"
    );
    assert!(
        report["audioFramesRead"].as_u64().unwrap() > 0,
        "report: {report_raw}"
    );
    assert!(
        report["waveConfirmsSent"].as_u64().unwrap() > 0,
        "report: {report_raw}"
    );
    assert_eq!(report["audioDrops"], 0, "report: {report_raw}");
    assert_eq!(report["errors"], serde_json::json!([]), "report: {report_raw}");

    let metrics = http_call(http_port, "GET", "/metrics", None).await;
    assert!(metrics["audioBlocksConfirmed"].as_u64().unwrap() > 0);

    let inputs = http_call(http_port, "GET", "/inputs", None).await;
    assert!(!inputs["events"].as_array().unwrap().is_empty());

    // Also test POST /control/deactivate and POST /control/disconnect on a second brief CLI session
    let script2 = tmp_dir.join("cli_smoke_actions2.json");
    let report2 = tmp_dir.join("cli_smoke_report2.json");
    let actions2 = serde_json::json!([
        { "type": "wait_active", "timeout_ms": 5000 },
        { "type": "wait_ms", "ms": 2000 }
    ]);
    std::fs::write(&script2, serde_json::to_vec_pretty(&actions2).unwrap()).unwrap();
    let cert_pin2 = format!("sha256:{}", server.cert_sha256());
    let cli_bin2 = env!("CARGO_BIN_EXE_aer-rdp-cli");
    let script2_arg = script2.clone();
    let report2_arg = report2.clone();
    let cli_handle2 = tokio::task::spawn_blocking(move || {
        Command::new(cli_bin2)
            .args([
                "--host",
                "127.0.0.1",
                "--port",
                &rdp_port.to_string(),
                "--auth",
                "nla",
                "--user",
                "testuser",
                "--pass",
                "testpass",
                "--trust-cert",
                &cert_pin2,
                "--script",
                script2_arg.to_str().unwrap(),
                "--out",
                report2_arg.to_str().unwrap(),
            ])
            .output()
            .expect("spawn aer-rdp-cli 2")
    });

    for _ in 0..40 {
        let m = http_call(http_port, "GET", "/metrics", None).await;
        if m["activeSessions"].as_u64().unwrap_or(0) > 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    let deact = http_call(http_port, "POST", "/control/deactivate", Some("{}")).await;
    assert_eq!(deact["ok"], true);
    for _ in 0..100 {
        let m = http_call(http_port, "GET", "/metrics", None).await;
        if m["reactivations"].as_u64().unwrap_or(0) >= 1 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let disc = http_call(http_port, "POST", "/control/disconnect", None).await;
    assert_eq!(disc["ok"], true);

    let out2 = cli_handle2.await.unwrap();
    assert!(out2.status.success(), "second CLI run failed");
    let m2 = http_call(http_port, "GET", "/metrics", None).await;
    assert!(m2["reactivations"].as_u64().unwrap() >= 1);

    let _ = std::fs::remove_file(&script_path);
    let _ = std::fs::remove_file(&report_path);
    let _ = std::fs::remove_file(&script2);
    let _ = std::fs::remove_file(&report2);
    server.shutdown().await;
}
