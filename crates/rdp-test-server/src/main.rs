use rdp_test_server::TestServerConfig;

fn main() {
    let cfg = TestServerConfig::default();
    println!(
        "aer-rdp test server bootstrap (bind={}, {}x{}, audio_hz={})",
        cfg.bind_addr, cfg.desktop_width, cfg.desktop_height, cfg.audio_hz
    );
}
