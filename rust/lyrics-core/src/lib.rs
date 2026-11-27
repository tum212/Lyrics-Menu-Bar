use std::sync::{Arc, OnceLock};
use std::time::Duration;

pub mod color;
pub mod dsp;
pub mod ffi;
pub mod haptics;
pub mod lyrics;
pub mod playback;
pub mod updater;

static SHARED_AGENT: OnceLock<ureq::Agent> = OnceLock::new();

pub(crate) fn shared_https_agent() -> &'static ureq::Agent {
    SHARED_AGENT.get_or_init(|| {
        let mut builder = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(15));

        if let Ok(conn) = native_tls::TlsConnector::new() {
            builder = builder.tls_connector(Arc::new(conn));
        }

        builder.build()
    })
}
