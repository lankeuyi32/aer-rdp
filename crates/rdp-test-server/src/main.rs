use std::net::SocketAddr;
use std::process::ExitCode;

use rdp_test_server::{AuthMode, MockConfig, MockRdpServer};

pub fn parse_cli_args<I>(mut args: I) -> Result<MockConfig, String>
where
    I: Iterator<Item = String>,
{
    let mut cfg = MockConfig {
        bind_addr: SocketAddr::from(([0, 0, 0, 0], 3389)),
        ..MockConfig::default()
    };
    let mut explicit_width = false;
    let mut explicit_height = false;

    while let Some(flag) = args.next() {
        let val = args
            .next()
            .ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--bind" => cfg.bind_addr = val.parse().map_err(|e| format!("invalid --bind: {e}"))?,
            "--auth" => {
                cfg.auth_mode = match val.to_ascii_lowercase().as_str() {
                    "auto" => AuthMode::Auto,
                    "nla" => AuthMode::Nla,
                    "tls" => AuthMode::Tls,
                    "none" => AuthMode::None,
                    _ => return Err(format!("invalid --auth: {val}")),
                };
            }
            "--user" => cfg.username = val,
            "--pass" => cfg.password = val,
            "--domain" => cfg.domain = val,
            "--width" => {
                cfg.desktop_width = val.parse().map_err(|e| format!("invalid --width: {e}"))?;
                explicit_width = true;
            }
            "--height" => {
                cfg.desktop_height = val.parse().map_err(|e| format!("invalid --height: {e}"))?;
                explicit_height = true;
            }
            "--audio-hz" => cfg.audio_hz = val.parse().map_err(|e| format!("invalid --audio-hz: {e}"))?,
            "--rdpsnd-version" => {
                cfg.rdpsnd_version = val
                    .parse()
                    .map_err(|e| format!("invalid --rdpsnd-version: {e}"))?;
            }
            "--control-http" => {
                cfg.control_http_addr = Some(
                    val.parse()
                        .map_err(|e| format!("invalid --control-http: {e}"))?,
                );
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    if !explicit_width && !explicit_height {
        cfg.honor_client_desktop_size = true;
    }
    Ok(cfg)
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> ExitCode {
    let cfg = match parse_cli_args(std::env::args().skip(1)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("rdp-test-server argument error: {e}");
            return ExitCode::from(2);
        }
    };

    let server = match MockRdpServer::start(cfg.clone()).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("failed to start rdp-test-server: {e}");
            return ExitCode::from(1);
        }
    };

    println!(
        "rdp-test-server listening on {}:{} (auth={:?}, rdpsnd_version={}, http_port={:?}, certSha256={})",
        cfg.bind_addr.ip(),
        server.port(),
        cfg.auth_mode,
        cfg.rdpsnd_version,
        server.http_port,
        server.cert_sha256(),
    );

    std::future::pending::<()>().await;
    server.shutdown().await;
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_parses_all_interface_contract_flags() {
        let args = [
            "--bind", "127.0.0.1:13389",
            "--auth", "nla",
            "--user", "alice",
            "--pass", "secret",
            "--domain", "AER",
            "--width", "1024",
            "--height", "768",
            "--audio-hz", "880",
            "--rdpsnd-version", "5",
            "--control-http", "127.0.0.1:13390",
        ]
        .into_iter()
        .map(str::to_owned);

        let cfg = parse_cli_args(args).unwrap();
        assert_eq!(cfg.bind_addr.port(), 13389);
        assert_eq!(cfg.auth_mode, AuthMode::Nla);
        assert_eq!(cfg.username, "alice");
        assert_eq!(cfg.password, "secret");
        assert_eq!(cfg.domain, "AER");
        assert_eq!(cfg.desktop_width, 1024);
        assert_eq!(cfg.desktop_height, 768);
        assert_eq!(cfg.audio_hz, 880);
        assert_eq!(cfg.rdpsnd_version, 5);
        assert_eq!(cfg.control_http_addr.unwrap().port(), 13390);
        assert!(!cfg.honor_client_desktop_size);
    }

    #[test]
    fn cli_honors_client_desktop_size_when_width_and_height_omitted() {
        let args = ["--bind", "127.0.0.1:13389", "--auth", "nla"]
            .into_iter()
            .map(str::to_owned);
        let cfg = parse_cli_args(args).unwrap();
        assert!(cfg.honor_client_desktop_size);
    }
}
