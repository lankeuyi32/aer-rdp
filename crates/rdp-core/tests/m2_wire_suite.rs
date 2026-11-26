use std::time::Duration;

use ironrdp::graphics::color_conversion::rdp_16bit_to_rgb;
use ironrdp::pdu::rdp::server_error_info::{ErrorInfo, ProtocolIndependentCode};
use rdp_core::{
    AudioMode, AuthCredentials, CertInfo, CertTrustDecision, ConnectConfig, SecurityMode,
    SessionEvent, SessionHandle, SessionState, connect,
};
use rdp_test_server::display::rgb888_to_rgb565_le;
use rdp_test_server::{AuthMode, MockConfig, MockRdpServer, PixelEncoding, PointerTestUpdate, RecordedInput};
use tokio::sync::mpsc;

async fn recv_until<F>(
    rx: &mut mpsc::UnboundedReceiver<SessionEvent>,
    timeout: Duration,
    mut pred: F,
) -> Option<SessionEvent>
where
    F: FnMut(&SessionEvent) -> bool,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            return None;
        }
        match tokio::time::timeout(deadline - now, rx.recv()).await {
            Ok(Some(ev)) => {
                if pred(&ev) {
                    return Some(ev);
                }
            }
            _ => return None,
        }
    }
}

async fn wait_for_metric<F>(server: &MockRdpServer, timeout: Duration, mut pred: F)
where
    F: FnMut(&rdp_test_server::MockMetrics) -> bool,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if pred(&server.metrics()) || tokio::time::Instant::now() >= deadline {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

async fn connect_and_accept_cert(
    cfg: ConnectConfig,
    creds: Option<AuthCredentials>,
) -> (SessionHandle, mpsc::UnboundedReceiver<SessionEvent>, Option<CertInfo>) {
    let (handle, mut rx) = connect(cfg, creds).expect("valid config");
    let mut captured_cert = None;

    let ev = recv_until(&mut rx, Duration::from_secs(5), |ev| match ev {
        SessionEvent::SessionStateChanged(SessionState::CertPrompt(info)) => {
            captured_cert = Some(info.clone());
            true
        }
        SessionEvent::SessionStateChanged(SessionState::Active { .. }) => true,
        SessionEvent::SessionStateChanged(SessionState::Disconnected { .. }) => true,
        _ => false,
    })
    .await
    .expect("timed out waiting for CertPrompt or Active");

    if matches!(
        ev,
        SessionEvent::SessionStateChanged(SessionState::CertPrompt(_))
    ) {
        handle
            .submit_cert_decision(CertTrustDecision::TrustOnce)
            .unwrap();
        let active = recv_until(&mut rx, Duration::from_secs(5), |e| {
            matches!(
                e,
                SessionEvent::SessionStateChanged(SessionState::Active { .. })
                    | SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
            )
        })
        .await
        .expect("timed out waiting for Active after CertPrompt");
        assert!(
            matches!(
                active,
                SessionEvent::SessionStateChanged(SessionState::Active { .. })
            ),
            "expected Active, got {active:?}"
        );
    } else {
        assert!(
            matches!(
                ev,
                SessionEvent::SessionStateChanged(SessionState::Active { .. })
            ),
            "expected Active, got {ev:?}"
        );
    }

    (handle, rx, captured_cert)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t01_tls_only_happy_path_and_cert_capture() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        cert_seed: Some([0x11u8; 32]),
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        ..Default::default()
    };

    let (handle, mut rx) = connect(
        cfg,
        Some(AuthCredentials {
            username: "testuser".to_owned(),
            domain: None,
            password: "testpass".to_owned(),
        }),
    )
    .unwrap();

    // CertPrompt must fire BEFORE Active/MCS
    let ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::CertPrompt(_))
                | SessionEvent::SessionStateChanged(SessionState::Active { .. })
        )
    })
    .await
    .unwrap();

    let cert_info = match ev {
        SessionEvent::SessionStateChanged(SessionState::CertPrompt(info)) => info,
        other => panic!("expected CertPrompt before Active, got {other:?}"),
    };
    assert_eq!(cert_info.sha256_hex, server.cert_sha256());

    handle
        .submit_cert_decision(CertTrustDecision::TrustOnce)
        .unwrap();

    let active = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Active { .. })
        )
    })
    .await;
    assert!(active.is_some());

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t02_cert_reject_aborts_before_auth_and_mcs() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Nla,
        cert_seed: Some([0x22u8; 32]),
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Nla,
        audio_mode: AudioMode::Off,
        ..Default::default()
    };
    let (handle, mut rx) = connect(
        cfg,
        Some(AuthCredentials {
            username: "testuser".to_owned(),
            domain: None,
            password: "testpass".to_owned(),
        }),
    )
    .unwrap();

    let ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::CertPrompt(_))
        )
    })
    .await
    .expect("CertPrompt expected");
    assert!(matches!(
        ev,
        SessionEvent::SessionStateChanged(SessionState::CertPrompt(_))
    ));

    handle
        .submit_cert_decision(CertTrustDecision::Reject)
        .unwrap();

    let disc = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await
    .expect("Disconnected expected after Reject");
    match disc {
        SessionEvent::SessionStateChanged(SessionState::Disconnected { reason, clean }) => {
            assert!(!clean);
            assert!(reason.to_lowercase().contains("rejected"));
        }
        _ => unreachable!(),
    }

    wait_for_metric(&server, Duration::from_millis(500), |m| m.active_sessions == 0).await;
    let m = server.metrics();
    assert_eq!(m.auth_failures, 0);
    assert_eq!(m.active_sessions, 0);
    assert!(m.total_connections <= 1);
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t03_cert_pin_trust_always_and_mismatch_reject() {
    let seed_a = [0xAAu8; 32];
    let seed_b = [0xBBu8; 32];

    let server_a = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        cert_seed: Some(seed_a),
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();
    let pin_a = server_a.cert_sha256().to_owned();

    let cfg_ok = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server_a.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(pin_a.clone()),
        ..Default::default()
    };
    let (handle, mut rx) = connect(
        cfg_ok,
        Some(AuthCredentials {
            username: "testuser".to_owned(),
            domain: None,
            password: "testpass".to_owned(),
        }),
    )
    .unwrap();

    let mut saw_prompt = false;
    let active = recv_until(&mut rx, Duration::from_secs(5), |e| match e {
        SessionEvent::SessionStateChanged(SessionState::CertPrompt(_)) => {
            saw_prompt = true;
            false
        }
        SessionEvent::SessionStateChanged(SessionState::Active { .. }) => true,
        _ => false,
    })
    .await;
    assert!(!saw_prompt, "pinned cert must skip CertPrompt");
    assert!(active.is_some());
    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server_a.shutdown().await;

    // Reconnect to server_b with pin_a -> mismatch before MCS & exposes new CertInfo
    let server_b = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        cert_seed: Some(seed_b),
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();
    let pin_b = server_b.cert_sha256().to_owned();
    assert_ne!(pin_a, pin_b);

    let cfg_bad = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server_b.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(pin_a),
        ..Default::default()
    };
    let (handle2, mut rx2) = connect(cfg_bad, None).unwrap();
    let disc = recv_until(&mut rx2, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await
    .expect("mismatch disconnect expected");
    match disc {
        SessionEvent::SessionStateChanged(SessionState::Disconnected { reason, clean }) => {
            assert!(!clean);
            assert!(reason.contains(&pin_b));
        }
        _ => unreachable!(),
    }
    assert_eq!(
        handle2.cert_info().map(|c| c.sha256_hex),
        Some(pin_b)
    );
    wait_for_metric(&server_b, Duration::from_millis(500), |m| m.active_sessions == 0).await;
    assert_eq!(server_b.metrics().active_sessions, 0);
    server_b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t04_nla_credssp_happy_path_and_auto_mode() {
    let nla_server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Nla,
        domain: "AER".to_owned(),
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    for mode in [SecurityMode::Nla, SecurityMode::Auto] {
        let cfg = ConnectConfig {
            host: "127.0.0.1".to_owned(),
            port: nla_server.port(),
            security_mode: mode,
            audio_mode: AudioMode::Off,
            pinned_cert_sha256: Some(nla_server.cert_sha256().to_owned()),
            ..Default::default()
        };
        let (handle, mut rx, _) = connect_and_accept_cert(
            cfg,
            Some(AuthCredentials {
                username: "testuser".to_owned(),
                domain: Some("AER".to_owned()),
                password: "testpass".to_owned(),
            }),
        )
        .await;
        let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::FrameUpdated { frame_sync: true, .. })
        })
        .await
        .expect("initial frame expected");
        handle.disconnect().unwrap();
        let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
            matches!(
                e,
                SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
            )
        })
        .await;
    }
    assert!(nla_server.metrics().frames_sent >= 2);
    nla_server.shutdown().await;

    // Auto fallback to TLS-only server
    let tls_server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();
    let cfg_auto = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: tls_server.port(),
        security_mode: SecurityMode::Auto,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(tls_server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(
        cfg_auto,
        Some(AuthCredentials {
            username: "testuser".to_owned(),
            domain: None,
            password: "testpass".to_owned(),
        }),
    )
    .await;
    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::FrameUpdated { frame_sync: true, .. })
    })
    .await
    .expect("initial frame expected for Auto->TLS fallback");
    wait_for_metric(&tls_server, Duration::from_millis(500), |m| m.frames_sent >= 1).await;
    assert!(tls_server.metrics().frames_sent >= 1);
    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    tls_server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t05_nla_wrong_creds_status_logon_failure_and_retry() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Nla,
        username: "u".to_owned(),
        password: "good".to_owned(),
        domain: "D".to_owned(),
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Nla,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx) = connect(
        cfg,
        Some(AuthCredentials {
            username: "u".to_owned(),
            domain: Some("D".to_owned()),
            password: "bad".to_owned(),
        }),
    )
    .unwrap();

    let prompt = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::AuthPrompt { .. })
        )
    })
    .await
    .expect("AuthPrompt expected on bad password");
    match prompt {
        SessionEvent::SessionStateChanged(SessionState::AuthPrompt { reason }) => {
            assert!(reason.is_some());
        }
        _ => unreachable!(),
    }
    wait_for_metric(&server, Duration::from_millis(500), |m| m.auth_failures == 1).await;
    assert_eq!(server.metrics().auth_failures, 1);

    handle
        .submit_credentials(AuthCredentials {
            username: "u".to_owned(),
            domain: Some("D".to_owned()),
            password: "good".to_owned(),
        })
        .unwrap();

    let active = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Active { .. })
        )
    })
    .await;
    assert!(active.is_some());
    wait_for_metric(&server, Duration::from_millis(500), |m| m.active_sessions == 1).await;
    assert_eq!(server.metrics().active_sessions, 1);

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t06_nla_wrong_domain_rejected() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Nla,
        username: "testuser".to_owned(),
        password: "testpass".to_owned(),
        domain: "CORP".to_owned(),
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Nla,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx) = connect(
        cfg,
        Some(AuthCredentials {
            username: "testuser".to_owned(),
            domain: Some("WRONG".to_owned()),
            password: "testpass".to_owned(),
        }),
    )
    .unwrap();

    let prompt = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::AuthPrompt { .. })
        )
    })
    .await;
    assert!(prompt.is_some());
    wait_for_metric(&server, Duration::from_millis(500), |m| {
        m.auth_failures == 1 && m.active_sessions == 0
    })
    .await;
    assert_eq!(server.metrics().auth_failures, 1);
    assert_eq!(server.metrics().active_sessions, 0);

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t07_mcs_gcc_channel_join_and_finalization() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        audio_hz: 440,
        auto_audio_interval_ms: Some(20),
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Local,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;

    let audio_ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::AudioStreamOpened { .. })
    })
    .await
    .expect("AudioStreamOpened expected when rdpsnd joined");
    assert!(matches!(
        audio_ev,
        SessionEvent::AudioStreamOpened {
            sample_rate: 48_000,
            channels: 2,
            bits_per_sample: 16
        }
    ));

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t08_deactivation_reactivation_same_size_and_resize() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Nla,
        desktop_width: 1280,
        desktop_height: 720,
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Nla,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(
        cfg,
        Some(AuthCredentials {
            username: "testuser".to_owned(),
            domain: None,
            password: "testpass".to_owned(),
        }),
    )
    .await;

    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::FrameUpdated { .. })
    })
    .await
    .expect("initial frame");

    // Same-size DeactivateAll
    server.trigger_deactivate_all(None).await.unwrap();
    let reactivating = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Reactivating)
        )
    })
    .await;
    assert!(reactivating.is_some());
    let active1 = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Active {
                width: 1280,
                height: 720
            })
        )
    })
    .await;
    assert!(active1.is_some());
    assert_eq!(server.metrics().reactivations, 1);

    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::FrameUpdated { .. })
    })
    .await
    .expect("post-reactivation frame");

    // Resize DeactivateAll (1024x600)
    server
        .trigger_deactivate_all(Some((1024, 600)))
        .await
        .unwrap();
    let active2 = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Active {
                width: 1024,
                height: 600
            })
        )
    })
    .await;
    assert!(active2.is_some());
    let (w, h, bytes) = handle.snapshot_rgba();
    assert_eq!((w, h), (1024, 600));
    assert_eq!(bytes.len(), 1024 * 600 * 4);

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t09_clean_client_and_server_disconnect_and_socket_drop() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();
    let pin = server.cert_sha256().to_owned();

    // (a) Clean client disconnect
    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(pin.clone()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg.clone(), None).await;
    handle.disconnect().unwrap();
    let disc = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await
    .expect("clean client disconnect");
    assert!(matches!(
        disc,
        SessionEvent::SessionStateChanged(SessionState::Disconnected { clean: true, .. })
    ));

    // (b) Server SetErrorInfo + DPUM
    let (_handle_b, mut rx_b, _) = connect_and_accept_cert(cfg.clone(), None).await;
    server
        .trigger_disconnect(ErrorInfo::ProtocolIndependentCode(
            ProtocolIndependentCode::RpcInitiatedDisconnect,
        ))
        .await
        .unwrap();
    let disc_b = recv_until(&mut rx_b, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await
    .expect("server ErrorInfo+DPUM disconnect");
    assert!(matches!(
        disc_b,
        SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
    ));

    // (c) Sudden socket drop
    let (handle_c, mut rx_c, _) = connect_and_accept_cert(cfg, None).await;
    handle_c.send_scancode(0x1E, false, true).unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
    server.trigger_socket_drop().await.unwrap();
    let disc_c = recv_until(&mut rx_c, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await
    .expect("socket drop disconnect");
    assert!(matches!(
        disc_c,
        SessionEvent::SessionStateChanged(SessionState::Disconnected { clean: false, .. })
    ));

    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t10_golden_pixels_raw_and_rle_16_24_32bpp() {
    let cases = [
        (PixelEncoding::Raw32, 322u16, 240u16, false),
        (PixelEncoding::Rdp6Rle32, 320u16, 240u16, false),
        (PixelEncoding::Raw24, 322u16, 240u16, false),
        (PixelEncoding::Rle24, 322u16, 240u16, false),
        (PixelEncoding::Raw16, 322u16, 240u16, true),
        (PixelEncoding::Rle16, 322u16, 240u16, true),
    ];

    for (enc, w, h, is_16bit) in cases {
        let server = MockRdpServer::start(MockConfig {
            auth_mode: AuthMode::Tls,
            desktop_width: w,
            desktop_height: h,
            pixel_encoding: enc,
            audio_hz: 0,
            honor_client_desktop_size: false,
            ..Default::default()
        })
        .await
        .unwrap();

        let cfg = ConnectConfig {
            host: "127.0.0.1".to_owned(),
            port: server.port(),
            width: w,
            height: h,
            security_mode: SecurityMode::Tls,
            audio_mode: AudioMode::Off,
            pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
            ..Default::default()
        };
        let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;

        let ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
            matches!(
                e,
                SessionEvent::FrameUpdated {
                    frame_sync: true,
                    ..
                }
            )
        })
        .await
        .unwrap_or_else(|| panic!("expected frame_sync FrameUpdated for {enc:?}"));
        assert!(matches!(ev, SessionEvent::FrameUpdated { frame_sync: true, .. }));

        let (fb_w, fb_h, rgba) = handle.snapshot_rgba();
        assert_eq!((fb_w, fb_h), (w, h));

        let px = |x: u16, y: u16| -> [u8; 3] {
            let idx = (usize::from(y) * usize::from(fb_w) + usize::from(x)) * 4;
            [rgba[idx], rgba[idx + 1], rgba[idx + 2]]
        };
        let expected_px = |r: u8, g: u8, b: u8| -> [u8; 3] {
            if is_16bit {
                let le = rgb888_to_rgb565_le(r, g, b);
                rdp_16bit_to_rgb(u16::from_le_bytes(le))
            } else {
                [r, g, b]
            }
        };

        // Golden anchor strip: (0..64, 0..16)
        assert_eq!(px(4, 4), expected_px(255, 0, 0), "red anchor {enc:?}");
        assert_eq!(px(20, 4), expected_px(0, 255, 0), "green anchor {enc:?}");
        assert_eq!(px(36, 4), expected_px(0, 0, 255), "blue anchor {enc:?}");
        assert_eq!(px(52, 4), expected_px(255, 255, 255), "white anchor {enc:?}");

        // Checkerboard tile at (16, 64): (16/32 + 64/32) % 2 == 0 -> #20242C
        assert_eq!(px(16, 64), expected_px(0x20, 0x24, 0x2C), "checkerboard {enc:?}");

        handle.disconnect().unwrap();
        let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
            matches!(
                e,
                SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
            )
        })
        .await;
        server.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn slow_path_bitmap_update_decoding() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        desktop_width: 320,
        desktop_height: 240,
        pixel_encoding: PixelEncoding::Raw24,
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        width: 320,
        height: 240,
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;
    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::FrameUpdated { frame_sync: true, .. })
    })
    .await;

    server
        .trigger_slowpath_frame(Some(PixelEncoding::Raw24))
        .await
        .unwrap();
    let sp_ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::FrameUpdated { .. })
    })
    .await;
    assert!(sp_ev.is_some(), "Slow-Path bitmap update must emit FrameUpdated");

    let (w, _, rgba) = handle.snapshot_rgba();
    let idx = (4 * usize::from(w) + 20) * 4;
    assert_eq!(&rgba[idx..idx + 3], &[0, 255, 0]);

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t11_pointer_updates_and_cache_reuse() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        audio_hz: 0,
        emit_initial_pointer: false,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        enable_server_pointer: true,
        pointer_software_rendering: false,
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;

    // 1. RGBA pointer (cache_index=1)
    let rgba_1 = [0x11, 0x22, 0x33, 0xFF].repeat(4);
    server
        .trigger_pointer_update(PointerTestUpdate::Rgba {
            cache_index: 1,
            width: 2,
            height: 2,
            hot_x: 1,
            hot_y: 1,
            rgba: rgba_1.clone(),
        })
        .await
        .unwrap();

    let c1 = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::CursorUpdated { width: 2, .. })
    })
    .await
    .expect("RGBA pointer update");
    match c1 {
        SessionEvent::CursorUpdated {
            hotspot_x,
            hotspot_y,
            rgba_pixels,
            visible,
            ..
        } => {
            assert!(visible);
            assert_eq!((hotspot_x, hotspot_y), (1, 1));
            assert_eq!(rgba_pixels.len(), 16);
        }
        _ => unreachable!(),
    }

    // 2. ColorPointer (cache_index=2) 1x1 24bpp BGR + 1-bit AND mask
    server
        .trigger_pointer_update(PointerTestUpdate::Color {
            cache_index: 2,
            width: 1,
            height: 1,
            hot_x: 0,
            hot_y: 0,
            xor_mask: vec![0x00, 0xFF, 0x00, 0x00],
            and_mask: vec![0x00, 0x00],
        })
        .await
        .unwrap();
    let c2 = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::CursorUpdated { width: 1, .. })
    })
    .await;
    assert!(c2.is_some());

    // 3. Position (120, 80)
    server
        .trigger_pointer_update(PointerTestUpdate::Position { x: 120, y: 80 })
        .await
        .unwrap();
    let pos_ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::CursorUpdated { x: 120, y: 80, .. }
        )
    })
    .await;
    assert!(pos_ev.is_some());

    // 4. Cached(1) reuse without re-transmitting bitmap
    server
        .trigger_pointer_update(PointerTestUpdate::Cached(1))
        .await
        .unwrap();
    let cached_ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::CursorUpdated {
                width: 2,
                hotspot_x: 1,
                ..
            }
        )
    })
    .await;
    assert!(cached_ev.is_some());

    // 5. Hidden, then Default
    server
        .trigger_pointer_update(PointerTestUpdate::Hidden)
        .await
        .unwrap();
    let hidden_ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::CursorUpdated { visible: false, .. })
    })
    .await;
    assert!(hidden_ev.is_some());

    server
        .trigger_pointer_update(PointerTestUpdate::Default)
        .await
        .unwrap();
    let def_ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::CursorUpdated {
                visible: true,
                width: 0,
                ..
            }
        )
    })
    .await;
    assert!(def_ev.is_some());

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

fn measure_pcm_energy_and_freq(pcm: &[u8], sample_rate: u32, channels: u16) -> (f64, f64) {
    let mut mono = Vec::new();
    let step = usize::from(channels.max(1));
    let samples: Vec<i16> = pcm
        .as_chunks::<2>()
        .0
        .iter()
        .map(|&c| i16::from_le_bytes(c))
        .collect();
    for frame in samples.chunks_exact(step) {
        mono.push(f64::from(frame[0]));
    }
    let rms = (mono.iter().map(|s| s * s).sum::<f64>() / mono.len().max(1) as f64).sqrt();
    let mut crossings = 0usize;
    for w in mono.windows(2) {
        if (w[0] <= 0.0 && w[1] > 0.0) || (w[0] >= 0.0 && w[1] < 0.0) {
            crossings += 1;
        }
    }
    let duration_s = mono.len() as f64 / f64::from(sample_rate);
    let freq_hz = (crossings as f64 / 2.0) / duration_s.max(1e-6);
    (rms, freq_hz)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t12_rdpsnd_v8_wave2_and_training_rtt() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        rdpsnd_version: 8,
        audio_hz: 440,
        auto_audio_interval_ms: None,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Local,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;

    server.trigger_rdpsnd_training(64).await.unwrap();
    server.trigger_audio_burst(10, 0).await.unwrap();

    let opened = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::AudioStreamOpened { .. })
    })
    .await;
    assert!(matches!(
        opened,
        Some(SessionEvent::AudioStreamOpened {
            sample_rate: 48_000,
            channels: 2,
            bits_per_sample: 16
        })
    ));

    // Wait for training RTT and all 10 blocks (200ms) to arrive
    wait_for_metric(
        &server,
        Duration::from_millis(500),
        |m| m.last_training_rtt_ms.is_some(),
    )
    .await;
    assert!(server.metrics().last_training_rtt_ms.is_some());
    for _ in 0..50 {
        if handle.audio_buffer().lock().unwrap().blocks_received() >= 10 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let mut all_pcm = Vec::new();
    let mut chunk = vec![0u8; 960 * 4];
    for _ in 0..10 {
        let st = handle.read_pcm_frames(&mut chunk, 960);
        if st.frames_read > 0 {
            all_pcm.extend_from_slice(&chunk[..st.frames_read * 4]);
        }
    }
    let (rms, freq) = measure_pcm_energy_and_freq(&all_pcm, 48_000, 2);
    assert!(rms > 1000.0, "expected strong 440Hz tone RMS, got {rms}");
    assert!(
        (freq - 440.0).abs() < 25.0,
        "expected ~440Hz zero-crossing freq, got {freq}"
    );

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t13_rdpsnd_legacy_v5_waveinfo_plus_wave() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        rdpsnd_version: 5,
        audio_hz: 440,
        auto_audio_interval_ms: None,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Local,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;
    server.trigger_audio_burst(6, 0).await.unwrap();

    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::AudioStreamOpened { .. })
    })
    .await
    .expect("AudioStreamOpened");
    tokio::time::sleep(Duration::from_millis(80)).await;

    let mut all_pcm = Vec::new();
    let mut chunk = vec![0u8; 960 * 4];
    for _ in 0..6 {
        let st = handle.read_pcm_frames(&mut chunk, 960);
        if st.frames_read > 0 {
            all_pcm.extend_from_slice(&chunk[..st.frames_read * 4]);
        }
    }
    let (rms, freq) = measure_pcm_energy_and_freq(&all_pcm, 48_000, 2);
    assert!(rms > 1000.0, "expected strong 440Hz tone in v5 SNDC_WAVE, got {rms}");
    assert!(
        (freq - 440.0).abs() < 30.0,
        "expected ~440Hz freq in v5 SNDC_WAVE, got {freq}"
    );

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t14_playout_paced_waveconfirm_not_eager() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        rdpsnd_version: 8,
        audio_hz: 440,
        auto_audio_interval_ms: None,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Local,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;
    // Wait briefly so initial rdpsnd format + training negotiation completes
    tokio::time::sleep(Duration::from_millis(80)).await;

    server.trigger_audio_burst(5, 0).await.unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::AudioStreamOpened { .. })
    })
    .await
    .expect("AudioStreamOpened");

    // Sleep 50ms WITHOUT calling read_pcm_frames -> zero WaveConfirm must be sent!
    tokio::time::sleep(Duration::from_millis(50)).await;
    let m_before = server.metrics();
    assert_eq!(m_before.audio_blocks_sent, 5);
    assert_eq!(
        m_before.audio_blocks_confirmed, 0,
        "WaveConfirm MUST NOT be sent eagerly before playback"
    );
    assert_eq!(m_before.in_flight_window, 5);

    // Now drain 100ms via read_pcm_frames -> all 5 WaveConfirms fire!
    let mut buf = vec![0u8; 960 * 4];
    for _ in 0..5 {
        let st = handle.read_pcm_frames(&mut buf, 960);
        assert_eq!(st.frames_read, 960);
    }

    // Allow async session loop to flush WaveConfirm PDUs onto TCP/TLS
    for _ in 0..30 {
        if server.metrics().audio_blocks_confirmed == 5 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let m_after = server.metrics();
    assert_eq!(m_after.audio_blocks_confirmed, 5);
    assert_eq!(m_after.in_flight_window, 0);

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t15_jitter_burst_drift_recovery_under_120ms() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        rdpsnd_version: 8,
        audio_hz: 440,
        auto_audio_interval_ms: None,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Local,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;
    tokio::time::sleep(Duration::from_millis(80)).await;

    // 15-block burst (300ms in <10ms)
    server.trigger_audio_burst(15, 0).await.unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::AudioStreamOpened { .. })
    })
    .await;
    // Wait for all 15 blocks to enter jitter buffer
    for _ in 0..30 {
        if handle.audio_buffer().lock().unwrap().blocks_received() == 15 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let mut out = vec![0u8; 960 * 4];
    let st1 = handle.read_pcm_frames(&mut out, 960);
    assert!(st1.drops > 0, "burst >150ms must trigger catch-up trim");
    assert!(st1.queued_ms <= 120, "queued_ms must recover <= 120ms, got {}", st1.queued_ms);
    assert!(st1.drift_ms.abs() <= 60, "drift_ms must be <= 60ms, got {}", st1.drift_ms);

    // Drain remaining 2 blocks
    for _ in 0..2 {
        let _ = handle.read_pcm_frames(&mut out, 960);
    }
    for _ in 0..30 {
        if server.metrics().in_flight_window == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(server.metrics().audio_blocks_confirmed, 15);
    assert_eq!(server.metrics().in_flight_window, 0);

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t16_input_roundtrip_pointer_scancode_unicode() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        pixel_encoding: PixelEncoding::Raw32,
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;
    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::FrameUpdated { frame_sync: true, .. })
    })
    .await;

    handle.send_pointer_event(250, 310, 0x01, true, 0).unwrap();
    handle.send_pointer_event(250, 310, 0x01, false, 120).unwrap();
    handle.send_scancode(0x1E, false, true).unwrap();
    handle.send_scancode(0x1E, false, false).unwrap();
    handle.send_scancode(0x4D, true, true).unwrap();
    handle.send_scancode(0x4D, true, false).unwrap();
    handle.send_unicode(0x4E2D, true).unwrap();
    handle.send_unicode(0x4E2D, false).unwrap();

    for _ in 0..30 {
        if server.recorded_inputs().len() >= 9 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let inputs = server.recorded_inputs();
    assert!(inputs.iter().any(|i| matches!(
        i,
        RecordedInput::Pointer { x: 250, y: 310, button_mask: 0x01, action, .. } if action == "button_down"
    )));
    assert!(inputs.iter().any(|i| matches!(
        i,
        RecordedInput::Pointer { wheel_delta: 120, action, .. } if action == "wheel_vertical"
    )));
    assert!(inputs.iter().any(|i| matches!(
        i,
        RecordedInput::Scancode { code: 0x1E, extended: false, down: true, .. }
    )));
    assert!(inputs.iter().any(|i| matches!(
        i,
        RecordedInput::Scancode { code: 0x4D, extended: true, down: true, .. }
    )));
    assert!(inputs.iter().any(|i| matches!(
        i,
        RecordedInput::Unicode { code_unit: 0x4E2D, down: true, .. }
    )));

    // Trigger frame and verify input-reactive box moved to (250, 310) (#FFB300)
    server.trigger_frame(None).await.unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::FrameUpdated { frame_sync: true, .. })
    })
    .await;

    let (w, _, rgba) = handle.snapshot_rgba();
    let idx = (310 * usize::from(w) + 250) * 4;
    assert_eq!(&rgba[idx..idx + 3], &[0xFF, 0xB3, 0x00]);

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn horizontal_vertical_wheel_and_buttons_1_2_3_roundtrip() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;
    let _ = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(e, SessionEvent::FrameUpdated { frame_sync: true, .. })
    })
    .await
    .expect("initial frame");

    // Buttons 1 (Left=0x01), 2 (Right=0x02), 3 (Middle=0x04) + vertical & horizontal wheels
    handle.send_pointer_event_hv(100, 100, 0x01, true, 0, 0).unwrap();
    handle.send_pointer_event_hv(100, 100, 0x01, false, 0, 0).unwrap();
    handle.send_pointer_event_hv(110, 110, 0x02, true, 0, 0).unwrap();
    handle.send_pointer_event_hv(110, 110, 0x02, false, 0, 0).unwrap();
    handle.send_pointer_event_hv(120, 120, 0x04, true, 0, 0).unwrap();
    handle.send_pointer_event_hv(120, 120, 0x04, false, 0, 0).unwrap();
    handle.send_pointer_event_hv(120, 120, 0x00, false, 120, -120).unwrap();

    for _ in 0..30 {
        if server.recorded_inputs().len() >= 10 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let inputs = server.recorded_inputs();
    assert!(inputs.iter().any(|i| matches!(
        i, RecordedInput::Pointer { button_mask: 0x01, action, .. } if action == "button_down"
    )));
    assert!(inputs.iter().any(|i| matches!(
        i, RecordedInput::Pointer { button_mask: 0x02, action, .. } if action == "button_down"
    )));
    assert!(inputs.iter().any(|i| matches!(
        i, RecordedInput::Pointer { button_mask: 0x04, action, .. } if action == "button_down"
    )));
    assert!(inputs.iter().any(|i| matches!(
        i, RecordedInput::Pointer { wheel_delta: 120, action, .. } if action == "wheel_vertical"
    )));
    assert!(inputs.iter().any(|i| matches!(
        i, RecordedInput::Pointer { wheel_delta: -120, action, .. } if action == "wheel_horizontal"
    )));

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn active_sessions_does_not_leak_on_post_activation_error_or_tls_reject() {
    use ironrdp_tokio::FramedWrite as _;
    use std::sync::{Arc, Mutex};
    use tokio::sync::Notify;

    // 1. Post-activation malformed X.224 PDU causes run_active_loop `?` error -> active_sessions returns to 0
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let jb = Arc::new(Mutex::new(rdp_core::AudioJitterBuffer::new(Arc::new(
        Notify::new(),
    ))));
    let (ev_tx, _ev_rx) = mpsc::unbounded_channel();
    let (_cmd_tx, mut cmd_rx) = mpsc::unbounded_channel();
    let mut conn = rdp_core::connector::connect_and_activate(&cfg, None, jb, &ev_tx, &mut cmd_rx)
        .await
        .expect("connect_and_activate");

    wait_for_metric(&server, Duration::from_millis(500), |m| m.active_sessions == 1).await;
    assert_eq!(server.metrics().active_sessions, 1);

    // Inject malformed TPKT/X.224 bytes directly into active session
    conn.framed
        .write_all(&[0x03, 0x00, 0x00, 0x08, 0xde, 0xad, 0xbe, 0xef])
        .await
        .unwrap();

    wait_for_metric(&server, Duration::from_millis(500), |m| m.active_sessions == 0).await;
    assert_eq!(
        server.metrics().active_sessions,
        0,
        "active_sessions must not leak on post-activation decode error"
    );
    drop(conn);
    server.shutdown().await;

    // 2. TLS-mode ClientInfo credential mismatch -> auth_failures == 1 and active_sessions == 0
    let tls_auth_srv = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        username: "u".to_owned(),
        password: "good".to_owned(),
        audio_hz: 0,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg2 = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: tls_auth_srv.port(),
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(tls_auth_srv.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (_handle2, mut rx2) = connect(
        cfg2,
        Some(AuthCredentials {
            username: "u".to_owned(),
            domain: None,
            password: "bad".to_owned(),
        }),
    )
    .unwrap();
    let _ = recv_until(&mut rx2, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await
    .expect("TLS ClientInfo mismatch should disconnect");

    wait_for_metric(&tls_auth_srv, Duration::from_millis(500), |m| {
        m.auth_failures == 1 && m.active_sessions == 0
    })
    .await;
    let m2 = tls_auth_srv.metrics();
    assert_eq!(m2.auth_failures, 1);
    assert_eq!(m2.active_sessions, 0);
    tls_auth_srv.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn odd_width_853x480_honored_without_stride_skew() {
    let server = MockRdpServer::start(MockConfig {
        auth_mode: AuthMode::Tls,
        desktop_width: 1280,
        desktop_height: 720,
        pixel_encoding: PixelEncoding::Rdp6Rle32,
        audio_hz: 0,
        honor_client_desktop_size: true,
        ..Default::default()
    })
    .await
    .unwrap();

    let cfg = ConnectConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        width: 853,
        height: 480,
        security_mode: SecurityMode::Tls,
        audio_mode: AudioMode::Off,
        pinned_cert_sha256: Some(server.cert_sha256().to_owned()),
        ..Default::default()
    };
    let (handle, mut rx, _) = connect_and_accept_cert(cfg, None).await;

    let ev = recv_until(&mut rx, Duration::from_secs(5), |e| {
        matches!(
            e,
            SessionEvent::FrameUpdated {
                frame_sync: true,
                ..
            }
        )
    })
    .await
    .expect("expected frame_sync FrameUpdated for 853x480");
    assert!(matches!(ev, SessionEvent::FrameUpdated { frame_sync: true, .. }));

    let (fb_w, fb_h, rgba) = handle.snapshot_rgba();
    assert_eq!((fb_w, fb_h), (853, 480));
    assert_eq!(rgba.len(), 853 * 480 * 4);

    let px = |x: u16, y: u16| -> [u8; 3] {
        let idx = (usize::from(y) * usize::from(fb_w) + usize::from(x)) * 4;
        [rgba[idx], rgba[idx + 1], rgba[idx + 2]]
    };

    // Golden anchor strip on top-left
    assert_eq!(px(4, 4), [255, 0, 0]);
    assert_eq!(px(20, 4), [0, 255, 0]);
    assert_eq!(px(36, 4), [0, 0, 255]);
    assert_eq!(px(52, 4), [255, 255, 255]);

    // Rightmost edge column (x = 852) across header and checkerboard bands (no stride skew)
    assert_eq!(px(852, 4), [0x1E, 0x88, 0xE5], "rightmost header pixel");
    assert_eq!(px(852, 64), [0x20, 0x24, 0x2C], "rightmost even checkerboard tile");
    assert_eq!(px(852, 96), [0x2E, 0x34, 0x40], "rightmost odd checkerboard tile");
    assert_eq!(px(852, 479), [0x20, 0x24, 0x2C], "bottom-right corner pixel");
    assert_eq!(px(0, 64), [0x20, 0x24, 0x2C], "left edge row 64");
    assert_eq!(px(0, 96), [0x2E, 0x34, 0x40], "left edge row 96");

    handle.disconnect().unwrap();
    let _ = recv_until(&mut rx, Duration::from_secs(3), |e| {
        matches!(
            e,
            SessionEvent::SessionStateChanged(SessionState::Disconnected { .. })
        )
    })
    .await;
    server.shutdown().await;
}
