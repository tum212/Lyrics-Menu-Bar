use std::sync::{Arc, OnceLock};
use std::time::Duration;

pub mod color;
pub mod dsp;
pub mod ffi;
pub mod haptics;
pub mod lyrics;
pub mod playback;
pub mod updater;

static SHARED_TLS: OnceLock<Option<Arc<native_tls::TlsConnector>>> = OnceLock::new();

pub(crate) fn build_https_agent(connect_secs: u64, read_secs: u64) -> ureq::Agent {
    let mut builder = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(connect_secs))
        .timeout_read(Duration::from_secs(read_secs));

    if let Some(conn) = SHARED_TLS
        .get_or_init(|| native_tls::TlsConnector::new().ok().map(Arc::new))
        .clone()
    {
        builder = builder.tls_connector(conn);
    }

    builder.build()
}
