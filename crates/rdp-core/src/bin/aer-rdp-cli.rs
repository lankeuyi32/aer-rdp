use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use rdp_core::{
    AudioMode, AuthCredentials, CertTrustDecision, ConnectConfig, SecurityMode, SessionEvent,
    SessionState, connect, normalize_sha256_pin,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone)]
enum TrustMode {
    Any,
    Pin(String),
    Reject,
}

#[derive(Debug)]
struct CliArgs {
    host: String,
    port: u16,
    auth: SecurityMode,
    user: String,
    pass: String,
    domain: String,
    width: u16,
    height: u16,
    audio: AudioMode,
    trust_cert: TrustMode,
    script: Option<PathBuf>,
    out: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ScriptAction {
    WaitActive {
        #[serde(default = "default_timeout_ms", alias = "timeoutMs")]
        timeout_ms: u64,
    },
    WaitFrames {
        #[serde(default = "default_min_frames", alias = "minFrames")]
        min_frames: u64,
        #[serde(default = "default_timeout_ms", alias = "timeoutMs")]
        timeout_ms: u64,
    },
    WaitAudioReady {
        #[serde(default = "default_timeout_ms", alias = "timeoutMs")]
        timeout_ms: u64,
        #[serde(default = "default_min_queued_ms", alias = "minQueuedMs")]
        min_queued_ms: u32,
    },
    Pointer {
        x: u16,
        y: u16,
        #[serde(default, alias = "buttonMask")]
        button_mask: u8,
        #[serde(default)]
        down: bool,
        #[serde(default, alias = "wheelDelta")]
        wheel_delta: i16,
        #[serde(default, alias = "wheelDeltaH")]
        wheel_delta_h: i16,
    },
    Scancode {
        code: u8,
        #[serde(default)]
        extended: bool,
        down: bool,
    },
    Unicode {
        #[serde(default, alias = "codeUnit")]
        code_unit: Option<u16>,
        #[serde(default)]
        down: Option<bool>,
        #[serde(default)]
        text: Option<String>,
    },
    DrainAudio {
        #[serde(alias = "durationMs")]
        ms: u64,
    },
    SetMute {
        muted: bool,
    },
    SetVolume {
        volume: f32,
    },
    WaitMs {
        #[serde(alias = "durationMs")]
        ms: u64,
    },
    Disconnect,
}

fn parse_script_json(txt: &str) -> Result<Vec<ScriptAction>, String> {
    let root: serde_json::Value =
        serde_json::from_str(txt).map_err(|e| format!("invalid JSON: {e}"))?;
    let raw_actions = match root {
        serde_json::Value::Array(arr) => arr,
        serde_json::Value::Object(mut obj) => match obj.remove("actions") {
            Some(serde_json::Value::Array(arr)) => arr,
            _ => {
                return Err(
                    "expected a JSON array or an object with an \"actions\" array".to_owned(),
                );
            }
        },
        _ => {
            return Err("expected a JSON array or an object with an \"actions\" array".to_owned());
        }
    };

    let mut actions = Vec::with_capacity(raw_actions.len());
    for (idx, item) in raw_actions.into_iter().enumerate() {
        let mut map = match item {
            serde_json::Value::Object(m) => m,
            _ => return Err(format!("actions[{idx}] must be a JSON object")),
        };
        match (map.get("type").cloned(), map.remove("action")) {
            (None, Some(action_val)) => {
                map.insert("type".to_owned(), action_val);
            }
            (Some(type_val), Some(action_val)) if type_val != action_val => {
                return Err(format!(
                    "actions[{idx}] has conflicting 'type' and 'action' fields"
                ));
            }
            (None, None) => {
                return Err(format!(
                    "actions[{idx}] missing field `action` or `type`"
                ));
            }
            _ => {}
        }
        let parsed: ScriptAction = serde_json::from_value(serde_json::Value::Object(map))
            .map_err(|e| format!("actions[{idx}]: {e}"))?;
        if let ScriptAction::Unicode {
            code_unit: None,
            text: None,
            ..
        } = &parsed
        {
            return Err(format!(
                "actions[{idx}]: unicode requires 'text' or 'code_unit'/'codeUnit'"
            ));
        }
        actions.push(parsed);
    }
    Ok(actions)
}

fn default_timeout_ms() -> u64 {
    5000
}

fn default_min_frames() -> u64 {
    1
}

fn default_min_queued_ms() -> u32 {
    50
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CliReport {
    connected: bool,
    final_state: String,
    cert_sha256: Option<String>,
    width: u16,
    height: u16,
    frames_received: u64,
    framebuffer_sha256: String,
    audio_frames_read: u64,
    audio_queued_ms: u32,
    audio_drift_ms: i64,
    audio_drops: u64,
    wave_confirms_sent: u64,
    disconnect_reason: Option<String>,
    errors: Vec<String>,
}

fn parse_args() -> Result<CliArgs, String> {
    let mut args = std::env::args().skip(1);
    let mut host = String::new();
    let mut port: u16 = 3389;
    let mut auth = SecurityMode::Auto;
    let mut user = String::new();
    let mut pass = String::new();
    let mut domain = String::new();
    let mut width: u16 = 1280;
    let mut height: u16 = 720;
    let mut audio = AudioMode::Local;
    let mut trust_cert = TrustMode::Any;
    let mut script: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;

    while let Some(flag) = args.next() {
        let val = args
            .next()
            .ok_or_else(|| format!("missing value for argument {flag}"))?;
        match flag.as_str() {
            "--host" => host = val,
            "--port" => port = val.parse().map_err(|e| format!("invalid --port: {e}"))?,
            "--auth" => {
                auth = match val.to_ascii_lowercase().as_str() {
                    "auto" => SecurityMode::Auto,
                    "nla" => SecurityMode::Nla,
                    "tls" => SecurityMode::Tls,
                    _ => return Err(format!("invalid --auth: {val}")),
                };
            }
            "--user" => user = val,
            "--pass" => pass = val,
            "--domain" => domain = val,
            "--width" => width = val.parse().map_err(|e| format!("invalid --width: {e}"))?,
            "--height" => height = val.parse().map_err(|e| format!("invalid --height: {e}"))?,
            "--audio" => {
                audio = match val.to_ascii_lowercase().as_str() {
                    "local" => AudioMode::Local,
                    "remote" => AudioMode::Remote,
                    "off" => AudioMode::Off,
                    _ => return Err(format!("invalid --audio: {val}")),
                };
            }
            "--trust-cert" => {
                if val.eq_ignore_ascii_case("any") {
                    trust_cert = TrustMode::Any;
                } else if val.eq_ignore_ascii_case("reject") {
                    trust_cert = TrustMode::Reject;
                } else {
                    trust_cert = TrustMode::Pin(normalize_sha256_pin(&val));
                }
            }
            "--script" => script = Some(PathBuf::from(val)),
            "--out" => out = Some(PathBuf::from(val)),
            other => return Err(format!("unknown argument {other}")),
        }
    }

    if host.is_empty() {
        return Err("--host is required".to_owned());
    }

    Ok(CliArgs {
        host,
        port,
        auth,
        user,
        pass,
        domain,
        width,
        height,
        audio,
        trust_cert,
        script,
        out,
    })
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(err) => {
            eprintln!("aer-rdp-cli argument error: {err}");
            return ExitCode::from(2);
        }
    };

    let actions: Vec<ScriptAction> = if let Some(path) = &args.script {
        match std::fs::read_to_string(path) {
            Ok(txt) => match parse_script_json(&txt) {
                Ok(parsed) => parsed,
                Err(e) => {
                    eprintln!("failed parsing --script JSON: {e}");
                    return ExitCode::from(2);
                }
            },
            Err(e) => {
                eprintln!("failed reading --script {}: {e}", path.display());
                return ExitCode::from(2);
            }
        }
    } else {
        vec![
            ScriptAction::WaitActive { timeout_ms: 5000 },
            ScriptAction::WaitMs { ms: 200 },
            ScriptAction::Disconnect,
        ]
    };

    let pinned_cert_sha256 = match &args.trust_cert {
        TrustMode::Pin(hex) => Some(hex.clone()),
        TrustMode::Any | TrustMode::Reject => None,
    };

    let cfg = ConnectConfig {
        host: args.host.clone(),
        port: args.port,
        width: args.width,
        height: args.height,
        security_mode: args.auth,
        audio_mode: args.audio,
        pinned_cert_sha256,
        ..Default::default()
    };

    let creds = if args.user.is_empty() && args.pass.is_empty() {
        None
    } else {
        Some(AuthCredentials {
            username: args.user.clone(),
            domain: if args.domain.is_empty() {
                None
            } else {
                Some(args.domain.clone())
            },
            password: args.pass.clone(),
        })
    };

    let mut report = CliReport {
        connected: false,
        final_state: "Init".to_owned(),
        cert_sha256: None,
        width: args.width,
        height: args.height,
        frames_received: 0,
        framebuffer_sha256: String::new(),
        audio_frames_read: 0,
        audio_queued_ms: 0,
        audio_drift_ms: 0,
        audio_drops: 0,
        wave_confirms_sent: 0,
        disconnect_reason: None,
        errors: Vec::new(),
    };

    let (handle, mut event_rx) = match connect(cfg, creds) {
        Ok(pair) => pair,
        Err(e) => {
            report.errors.push(e.to_string());
            emit_report(&report, args.out.as_ref());
            return ExitCode::from(1);
        }
    };

    let mut is_active = false;
    let mut is_disconnected = false;
    let mut audio_stream_opened = false;

    for action in actions {
        match action {
            ScriptAction::WaitActive { timeout_ms } => {
                let deadline = tokio::time::Instant::now() + Duration::from_millis(timeout_ms);
                while !is_active && !is_disconnected {
                    let now = tokio::time::Instant::now();
                    if now >= deadline {
                        report.errors.push(format!("timeout waiting for Active ({timeout_ms}ms)"));
                        break;
                    }
                    match tokio::time::timeout(deadline - now, event_rx.recv()).await {
                        Ok(Some(ev)) => {
                            process_event(
                                &ev,
                                &handle,
                                &args.trust_cert,
                                &mut report,
                                &mut is_active,
                                &mut is_disconnected,
                                &mut audio_stream_opened,
                            );
                        }
                        Ok(None) => {
                            is_disconnected = true;
                            break;
                        }
                        Err(_) => {
                            report.errors.push(format!("timeout waiting for Active ({timeout_ms}ms)"));
                            break;
                        }
                    }
                }
            }
            ScriptAction::WaitFrames {
                min_frames,
                timeout_ms,
            } => {
                let deadline = tokio::time::Instant::now() + Duration::from_millis(timeout_ms);
                while report.frames_received < min_frames && !is_disconnected {
                    let now = tokio::time::Instant::now();
                    if now >= deadline {
                        report.errors.push(format!(
                            "timeout waiting for {min_frames} frames (got {}, {timeout_ms}ms)",
                            report.frames_received
                        ));
                        break;
                    }
                    match tokio::time::timeout(deadline - now, event_rx.recv()).await {
                        Ok(Some(ev)) => {
                            process_event(
                                &ev,
                                &handle,
                                &args.trust_cert,
                                &mut report,
                                &mut is_active,
                                &mut is_disconnected,
                                &mut audio_stream_opened,
                            );
                        }
                        Ok(None) => {
                            is_disconnected = true;
                            break;
                        }
                        Err(_) => {
                            report.errors.push(format!(
                                "timeout waiting for {min_frames} frames (got {}, {timeout_ms}ms)",
                                report.frames_received
                            ));
                            break;
                        }
                    }
                }
            }
            ScriptAction::WaitAudioReady {
                timeout_ms,
                min_queued_ms,
            } => {
                let deadline = tokio::time::Instant::now() + Duration::from_millis(timeout_ms);
                loop {
                    let queued_ms = {
                        let jb = handle.audio_buffer();
                        let guard = jb.lock().unwrap();
                        guard.queued_ms()
                    };
                    if (audio_stream_opened && queued_ms >= min_queued_ms) || is_disconnected {
                        break;
                    }
                    let now = tokio::time::Instant::now();
                    if now >= deadline {
                        report.errors.push(format!(
                            "timeout waiting for audio ready (opened={audio_stream_opened}, queued_ms={queued_ms}, min_queued_ms={min_queued_ms}, {timeout_ms}ms)"
                        ));
                        break;
                    }
                    let slice = (deadline - now).min(Duration::from_millis(15));
                    match tokio::time::timeout(slice, event_rx.recv()).await {
                        Ok(Some(ev)) => {
                            process_event(
                                &ev,
                                &handle,
                                &args.trust_cert,
                                &mut report,
                                &mut is_active,
                                &mut is_disconnected,
                                &mut audio_stream_opened,
                            );
                        }
                        Ok(None) => {
                            is_disconnected = true;
                            break;
                        }
                        Err(_) => {}
                    }
                }
            }
            ScriptAction::Pointer {
                x,
                y,
                button_mask,
                down,
                wheel_delta,
                wheel_delta_h,
            } => {
                if let Err(e) = handle.send_pointer_event_hv(x, y, button_mask, down, wheel_delta, wheel_delta_h) {
                    report.errors.push(e.to_string());
                }
            }
            ScriptAction::Scancode {
                code,
                extended,
                down,
            } => {
                if let Err(e) = handle.send_scancode(code, extended, down) {
                    report.errors.push(e.to_string());
                }
            }
            ScriptAction::Unicode {
                code_unit,
                down,
                text,
            } => {
                if let Some(txt) = text {
                    for unit in txt.encode_utf16() {
                        if let Err(e) = handle.send_unicode(unit, true) {
                            report.errors.push(e.to_string());
                            break;
                        }
                        if let Err(e) = handle.send_unicode(unit, false) {
                            report.errors.push(e.to_string());
                            break;
                        }
                    }
                } else if let Some(unit) = code_unit {
                    let is_down = down.unwrap_or(true);
                    if let Err(e) = handle.send_unicode(unit, is_down) {
                        report.errors.push(e.to_string());
                    }
                }
            }
            ScriptAction::DrainAudio { ms } => {
                let steps = (ms / 20).max(1);
                let mut pcm_out = Vec::new();
                let step_dur = Duration::from_millis(20);
                let mut tick =
                    tokio::time::interval_at(tokio::time::Instant::now() + step_dur, step_dur);
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Burst);
                for _ in 0..steps {
                    if is_disconnected {
                        break;
                    }
                    tick.tick().await;
                    drain_pending_events(
                        &mut event_rx,
                        &handle,
                        &args.trust_cert,
                        &mut report,
                        &mut is_active,
                        &mut is_disconnected,
                        &mut audio_stream_opened,
                    );
                    if is_disconnected {
                        break;
                    }
                    let (sample_rate, frame_bytes) = {
                        let jb = handle.audio_buffer();
                        let guard = jb.lock().unwrap();
                        let fmt = guard.format();
                        (fmt.sample_rate, fmt.frame_bytes())
                    };
                    let frames_per_step = ((u64::from(sample_rate) * 20) / 1000).max(1) as usize;
                    let target_len = frames_per_step * frame_bytes.max(1);
                    if pcm_out.len() != target_len {
                        pcm_out.resize(target_len, 0);
                    }
                    let stats = handle.read_pcm_frames(&mut pcm_out, frames_per_step);
                    report.audio_frames_read += stats.frames_read as u64;
                    report.audio_queued_ms = stats.queued_ms;
                    report.audio_drift_ms = stats.drift_ms;
                    report.audio_drops = stats.drops;
                }
                if !is_disconnected {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            }
            ScriptAction::SetMute { muted } => {
                if let Err(e) = handle.set_audio_mute(muted) {
                    report.errors.push(e.to_string());
                }
            }
            ScriptAction::SetVolume { volume } => {
                if let Err(e) = handle.set_audio_volume(volume) {
                    report.errors.push(e.to_string());
                }
            }
            ScriptAction::WaitMs { ms } => {
                let deadline = tokio::time::Instant::now() + Duration::from_millis(ms);
                while tokio::time::Instant::now() < deadline && !is_disconnected {
                    let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
                    match tokio::time::timeout(rem, event_rx.recv()).await {
                        Ok(Some(ev)) => {
                            process_event(
                                &ev,
                                &handle,
                                &args.trust_cert,
                                &mut report,
                                &mut is_active,
                                &mut is_disconnected,
                                &mut audio_stream_opened,
                            );
                        }
                        Ok(None) => {
                            is_disconnected = true;
                            break;
                        }
                        Err(_) => break,
                    }
                }
            }
            ScriptAction::Disconnect => {
                if is_active && report.frames_received == 0 && !is_disconnected {
                    let frame_deadline = tokio::time::Instant::now() + Duration::from_millis(1500);
                    while report.frames_received == 0 && !is_disconnected {
                        let now = tokio::time::Instant::now();
                        if now >= frame_deadline {
                            break;
                        }
                        match tokio::time::timeout(frame_deadline - now, event_rx.recv()).await {
                            Ok(Some(ev)) => {
                                process_event(
                                    &ev,
                                    &handle,
                                    &args.trust_cert,
                                    &mut report,
                                    &mut is_active,
                                    &mut is_disconnected,
                                    &mut audio_stream_opened,
                                );
                            }
                            Ok(None) => {
                                is_disconnected = true;
                                break;
                            }
                            Err(_) => break,
                        }
                    }
                }
                let _ = handle.disconnect();
                let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
                while !is_disconnected && tokio::time::Instant::now() < deadline {
                    let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
                    match tokio::time::timeout(rem, event_rx.recv()).await {
                        Ok(Some(ev)) => {
                            process_event(
                                &ev,
                                &handle,
                                &args.trust_cert,
                                &mut report,
                                &mut is_active,
                                &mut is_disconnected,
                                &mut audio_stream_opened,
                            );
                        }
                        Ok(None) => {
                            is_disconnected = true;
                            break;
                        }
                        Err(_) => break,
                    }
                }
            }
        }
    }

    drain_pending_events(
        &mut event_rx,
        &handle,
        &args.trust_cert,
        &mut report,
        &mut is_active,
        &mut is_disconnected,
        &mut audio_stream_opened,
    );

    if report.cert_sha256.is_none() {
        report.cert_sha256 = handle.cert_info().map(|c| c.sha256_hex);
    }

    let (w, h, _) = handle.snapshot_rgba();
    report.width = w;
    report.height = h;
    report.framebuffer_sha256 = handle.framebuffer_sha256_hex();

    {
        let jb = handle.audio_buffer();
        let guard = jb.lock().unwrap();
        let st = guard.stats(0);
        report.audio_queued_ms = st.queued_ms;
        report.audio_drift_ms = st.drift_ms;
        report.audio_drops = st.drops;
        report.wave_confirms_sent = st.wave_confirms_sent;
    }

    emit_report(&report, args.out.as_ref());

    if report.errors.is_empty() && report.connected {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

fn drain_pending_events(
    event_rx: &mut tokio::sync::mpsc::UnboundedReceiver<SessionEvent>,
    handle: &rdp_core::SessionHandle,
    trust_mode: &TrustMode,
    report: &mut CliReport,
    is_active: &mut bool,
    is_disconnected: &mut bool,
    audio_stream_opened: &mut bool,
) {
    while let Ok(ev) = event_rx.try_recv() {
        process_event(
            &ev,
            handle,
            trust_mode,
            report,
            is_active,
            is_disconnected,
            audio_stream_opened,
        );
    }
}

fn process_event(
    ev: &SessionEvent,
    handle: &rdp_core::SessionHandle,
    trust_mode: &TrustMode,
    report: &mut CliReport,
    is_active: &mut bool,
    is_disconnected: &mut bool,
    audio_stream_opened: &mut bool,
) {
    match ev {
        SessionEvent::SessionStateChanged(state) => match state {
            SessionState::Connecting => report.final_state = "Connecting".to_owned(),
            SessionState::CertPrompt(info) => {
                report.final_state = "CertPrompt".to_owned();
                report.cert_sha256 = Some(info.sha256_hex.clone());
                let decision = match trust_mode {
                    TrustMode::Any => CertTrustDecision::TrustOnce,
                    TrustMode::Reject => CertTrustDecision::Reject,
                    TrustMode::Pin(expected) => {
                        if info.sha256_hex == *expected {
                            CertTrustDecision::TrustAlways
                        } else {
                            CertTrustDecision::Reject
                        }
                    }
                };
                let _ = handle.submit_cert_decision(decision);
            }
            SessionState::AuthPrompt { reason } => {
                report.final_state = "AuthPrompt".to_owned();
                if let Some(r) = reason {
                    report.errors.push(format!("auth failed: {r}"));
                }
                let _ = handle.disconnect();
            }
            SessionState::Active { width, height } => {
                report.connected = true;
                report.final_state = "Active".to_owned();
                report.width = *width;
                report.height = *height;
                *is_active = true;
            }
            SessionState::Reactivating => {
                report.final_state = "Reactivating".to_owned();
            }
            SessionState::Disconnected { reason, clean } => {
                report.final_state = "Disconnected".to_owned();
                report.disconnect_reason = Some(reason.clone());
                *is_disconnected = true;
                if !clean && !report.connected {
                    report.errors.push(reason.clone());
                }
            }
        },
        SessionEvent::FrameUpdated { width, height, .. } => {
            report.frames_received += 1;
            report.width = *width;
            report.height = *height;
        }
        SessionEvent::AudioStreamOpened { .. } => {
            *audio_stream_opened = true;
        }
        SessionEvent::CursorUpdated { .. } | SessionEvent::AudioVolumeChanged { .. } => {}
    }
}

fn emit_report(report: &CliReport, out_path: Option<&PathBuf>) {
    let json = serde_json::to_string_pretty(report).unwrap_or_else(|_| "{}".to_owned());
    println!("{json}");
    if let Some(path) = out_path {
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, json);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_e2e_action_camelcase_and_unicode_text() {
        let raw = r#"[
            {"action": "wait_active", "timeoutMs": 3500},
            {"action": "wait_frames", "minFrames": 2, "timeoutMs": 4000},
            {"action": "wait_audio_ready", "minQueuedMs": 60, "timeoutMs": 4500},
            {"action": "pointer", "x": 120, "y": 240, "buttonMask": 1, "down": true, "wheelDelta": -120, "wheelDeltaH": 30},
            {"action": "scancode", "code": 30, "extended": true, "down": false},
            {"action": "unicode", "text": "你好é"},
            {"action": "unicode", "codeUnit": 65},
            {"action": "drain_audio", "durationMs": 600},
            {"action": "set_mute", "muted": true},
            {"action": "set_volume", "volume": 0.5},
            {"action": "wait_ms", "durationMs": 250},
            {"action": "disconnect"}
        ]"#;
        let parsed = parse_script_json(raw).expect("valid e2e script");
        assert_eq!(parsed.len(), 12);
        assert_eq!(parsed[0], ScriptAction::WaitActive { timeout_ms: 3500 });
        assert_eq!(
            parsed[1],
            ScriptAction::WaitFrames {
                min_frames: 2,
                timeout_ms: 4000
            }
        );
        assert_eq!(
            parsed[2],
            ScriptAction::WaitAudioReady {
                timeout_ms: 4500,
                min_queued_ms: 60
            }
        );
        assert_eq!(
            parsed[3],
            ScriptAction::Pointer {
                x: 120,
                y: 240,
                button_mask: 1,
                down: true,
                wheel_delta: -120,
                wheel_delta_h: 30,
            }
        );
        assert_eq!(
            parsed[5],
            ScriptAction::Unicode {
                code_unit: None,
                down: None,
                text: Some("你好é".to_owned()),
            }
        );
        assert_eq!(
            parsed[6],
            ScriptAction::Unicode {
                code_unit: Some(65),
                down: None,
                text: None,
            }
        );
        assert_eq!(parsed[7], ScriptAction::DrainAudio { ms: 600 });
        assert_eq!(parsed[10], ScriptAction::WaitMs { ms: 250 });
        assert_eq!(parsed[11], ScriptAction::Disconnect);
    }

    #[test]
    fn parses_actions_wrapper_object_and_legacy_type_snakecase() {
        let raw = r#"{"actions": [
            {"type": "wait_active", "timeout_ms": 5000},
            {"type": "unicode", "code_unit": 65, "down": false},
            {"type": "drain_audio", "ms": 300},
            {"type": "disconnect"}
        ]}"#;
        let parsed = parse_script_json(raw).expect("valid wrapped script");
        assert_eq!(parsed.len(), 4);
        assert_eq!(parsed[0], ScriptAction::WaitActive { timeout_ms: 5000 });
        assert_eq!(
            parsed[1],
            ScriptAction::Unicode {
                code_unit: Some(65),
                down: Some(false),
                text: None,
            }
        );
        assert_eq!(parsed[2], ScriptAction::DrainAudio { ms: 300 });
        assert_eq!(parsed[3], ScriptAction::Disconnect);
    }

    #[test]
    fn rejects_unicode_without_text_or_code_unit() {
        let raw = r#"[{"action": "unicode"}]"#;
        assert!(parse_script_json(raw).is_err());
    }
}
