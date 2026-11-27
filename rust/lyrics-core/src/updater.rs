use std::fs::File;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::{Deserialize, Serialize};

pub const REMOTE_CONFIG_URL: &str =
    "https://raw.githubusercontent.com/tum212/Lyrics-Menu-Bar/main/remote_config.json";
pub const GITHUB_LATEST_RELEASE_URL: &str =
    "https://api.github.com/repos/tum212/Lyrics-Menu-Bar/releases/latest";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LyricsEndpointsConfig {
    pub lrclib_search: String,
    pub lrclib_get: String,
    pub lyrics_ovh: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AnnouncementConfig {
    pub id: String,
    pub title: String,
    pub message: String,
    pub action_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RemoteConfig {
    pub version: String,
    pub build: i32,
    pub release_date: Option<String>,
    pub release_notes: Option<String>,
    pub download_url: Option<String>,
    pub download_url_lite: Option<String>,
    pub mandatory: Option<bool>,
    pub lyrics_endpoints: Option<LyricsEndpointsConfig>,
    pub announcement: Option<AnnouncementConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateCheckOutcome {
    pub update_available: bool,
    pub version: String,
    pub release_notes: String,
    pub download_url: String,
    pub endpoints: Option<LyricsEndpointsConfig>,
}

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    body: String,
    assets: Vec<GitHubAsset>,
}

#[derive(Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
}

pub fn is_version_greater(remote: &str, local: &str) -> bool {
    let parse = |s: &str| -> Vec<i64> {
        s.trim_matches(|c: char| c == 'v' || c == 'V' || c.is_whitespace())
            .split('.')
            .filter_map(|p| p.parse::<i64>().ok())
            .collect()
    };
    let r = parse(remote);
    let l = parse(local);
    let max_len = r.len().max(l.len());
    for i in 0..max_len {
        let rv = *r.get(i).unwrap_or(&0);
        let lv = *l.get(i).unwrap_or(&0);
        if rv > lv {
            return true;
        }
        if rv < lv {
            return false;
        }
    }
    false
}

pub fn check_updates(current_version: &str, current_build: i32) -> UpdateCheckOutcome {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(Duration::from_secs(10))
        .build();
    let ua = format!("LyricsMenuBar/{current_version}");

    let mut endpoints: Option<LyricsEndpointsConfig> = None;

    if let Ok(resp) = agent
        .get(REMOTE_CONFIG_URL)
        .set("User-Agent", &ua)
        .set("Cache-Control", "no-cache")
        .call()
    {
        if (200..=299).contains(&resp.status()) {
            if let Ok(cfg) = resp.into_json::<RemoteConfig>() {
                endpoints = cfg.lyrics_endpoints.clone();
                if let Some(dl_url) = cfg.download_url.clone() {
                    let newer_ver = is_version_greater(&cfg.version, current_version);
                    let newer_bld = cfg.version == current_version && cfg.build > current_build;
                    if newer_ver || newer_bld {
                        return UpdateCheckOutcome {
                            update_available: true,
                            version: cfg.version,
                            release_notes: cfg.release_notes.unwrap_or_else(|| {
                                "A new update for Lyrics Menu Bar is ready.".to_string()
                            }),
                            download_url: dl_url,
                            endpoints,
                        };
                    }
                }
            }
        }
    }

    // Fallback to GitHub Releases API
    if let Ok(resp) = agent
        .get(GITHUB_LATEST_RELEASE_URL)
        .set("User-Agent", &ua)
        .set("Cache-Control", "no-cache")
        .call()
    {
        if (200..=299).contains(&resp.status()) {
            if let Ok(rel) = resp.into_json::<GitHubRelease>() {
                let tag = rel
                    .tag_name
                    .trim_matches(|c: char| c == 'v' || c == 'V' || c.is_whitespace())
                    .to_string();
                if is_version_greater(&tag, current_version) {
                    if let Some(asset) = rel.assets.into_iter().find(|a| a.name.ends_with(".dmg")) {
                        return UpdateCheckOutcome {
                            update_available: true,
                            version: tag,
                            release_notes: rel.body,
                            download_url: asset.browser_download_url,
                            endpoints,
                        };
                    }
                }
            }
        }
    }

    UpdateCheckOutcome {
        update_available: false,
        version: current_version.to_string(),
        release_notes: String::new(),
        download_url: String::new(),
        endpoints,
    }
}

pub fn download_dmg_streaming<F: FnMut(f64)>(
    url: &str,
    dest_path: &str,
    cancel_flag: &AtomicBool,
    mut on_progress: F,
) -> Result<(), String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(60))
        .build();

    let resp = agent
        .get(url)
        .set("User-Agent", "LyricsMenuBar/2.0")
        .call()
        .map_err(|e| format!("Network request failed: {e}"))?;

    if !(200..=299).contains(&resp.status()) {
        return Err(format!("Server returned status {}", resp.status()));
    }

    let total_bytes: u64 = resp
        .header("Content-Length")
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);

    let mut file =
        File::create(dest_path).map_err(|e| format!("Failed to create update file: {e}"))?;
    let mut reader = resp.into_reader();
    let mut buf = [0_u8; 32 * 1024];
    let mut written: u64 = 0;

    loop {
        if cancel_flag.load(Ordering::Acquire) {
            let _ = std::fs::remove_file(dest_path);
            return Err("Cancelled".to_string());
        }
        let n = reader
            .read(&mut buf)
            .map_err(|e| format!("Read stream failed: {e}"))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])
            .map_err(|e| format!("Disk write failed: {e}"))?;
        written += n as u64;
        if total_bytes > 0 {
            on_progress((written as f64 / total_bytes as f64).clamp(0.0, 1.0));
        }
    }
    file.flush()
        .map_err(|e| format!("Disk flush failed: {e}"))?;
    on_progress(1.0);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version_compare() {
        assert!(is_version_greater("2.0.0", "1.3.1"));
        assert!(is_version_greater("v2.0.1", "2.0.0"));
        assert!(is_version_greater("1.3.10", "1.3.2"));
        assert!(!is_version_greater("v2.0.0", "2.0.0"));
        assert!(!is_version_greater("1.3.1", "2.0.0"));
    }
}
