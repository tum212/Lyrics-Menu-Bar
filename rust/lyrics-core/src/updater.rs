use std::fs::File;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

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
    body: Option<String>,
    assets: Vec<GitHubAsset>,
}

#[derive(Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
}

fn parse_semver(s: &str) -> (Vec<i64>, Option<String>) {
    let trimmed = s.trim().trim_start_matches(['v', 'V']);
    let (core, pre) = match trimmed.split_once('-') {
        Some((c, p)) => (c, Some(p.to_string())),
        None => (trimmed, None),
    };
    let nums: Vec<i64> = core
        .split('.')
        .map(|p| p.parse::<i64>().unwrap_or(0))
        .collect();
    (nums, pre)
}

pub fn is_version_greater(remote: &str, local: &str) -> bool {
    let (r, r_pre) = parse_semver(remote);
    let (l, l_pre) = parse_semver(local);
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
    // Equal numeric tuple: stable (None) > prerelease (Some)
    match (r_pre, l_pre) {
        (None, Some(_)) => true,
        (Some(_), None) => false,
        (Some(rp), Some(lp)) => rp > lp,
        (None, None) => false,
    }
}

fn normalized_ver(s: &str) -> &str {
    s.trim().trim_start_matches(['v', 'V'])
}

pub fn check_updates(current_version: &str, current_build: i32) -> UpdateCheckOutcome {
    let agent = crate::shared_https_agent();
    let ua = format!("LyricsMenuBar/{current_version}");
    let mut endpoints: Option<LyricsEndpointsConfig> = None;

    if let Ok(resp) = agent
        .get(REMOTE_CONFIG_URL)
        .timeout(Duration::from_secs(10))
        .set("User-Agent", &ua)
        .set("Cache-Control", "no-cache")
        .call()
    {
        if (200..=299).contains(&resp.status()) {
            if let Ok(cfg) = resp.into_json::<RemoteConfig>() {
                endpoints = cfg.lyrics_endpoints.clone();
                if let Some(dl_url) = cfg.download_url.clone().filter(|u| !u.trim().is_empty()) {
                    let newer_ver = is_version_greater(&cfg.version, current_version);
                    let same_ver = normalized_ver(&cfg.version) == normalized_ver(current_version);
                    let newer_bld = same_ver && cfg.build > current_build;
                    if newer_ver || newer_bld {
                        return UpdateCheckOutcome {
                            update_available: true,
                            version: normalized_ver(&cfg.version).to_string(),
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

    if let Ok(resp) = agent
        .get(GITHUB_LATEST_RELEASE_URL)
        .timeout(Duration::from_secs(10))
        .set("User-Agent", &ua)
        .set("Cache-Control", "no-cache")
        .call()
    {
        if (200..=299).contains(&resp.status()) {
            if let Ok(rel) = resp.into_json::<GitHubRelease>() {
                let tag = normalized_ver(&rel.tag_name).to_string();
                if is_version_greater(&tag, current_version) {
                    if let Some(asset) = rel
                        .assets
                        .into_iter()
                        .find(|a| a.name.ends_with(".dmg") && !a.browser_download_url.is_empty())
                    {
                        return UpdateCheckOutcome {
                            update_available: true,
                            version: tag,
                            release_notes: rel.body.unwrap_or_default(),
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
    let resp = crate::shared_https_agent()
        .get(url)
        .timeout(Duration::from_secs(120))
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

    let part_path = format!("{dest_path}.part");
    let _ = std::fs::remove_file(&part_path);

    let result: Result<(), String> = (|| {
        let mut file =
            File::create(&part_path).map_err(|e| format!("Failed to create update file: {e}"))?;
        let mut reader = resp.into_reader();
        let mut buf = [0_u8; 32 * 1024];
        let mut written: u64 = 0;
        let mut last_pct: f64 = -1.0;
        let mut last_emit = Instant::now();

        loop {
            if cancel_flag.load(Ordering::Acquire) {
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
                let pct = (written as f64 / total_bytes as f64).clamp(0.0, 1.0);
                if (pct - last_pct) >= 0.01 || last_emit.elapsed() >= Duration::from_millis(50) {
                    last_pct = pct;
                    last_emit = Instant::now();
                    on_progress(pct);
                }
            }
        }
        file.flush()
            .map_err(|e| format!("Disk flush failed: {e}"))?;
        if written == 0 || (total_bytes > 0 && written != total_bytes) {
            return Err(format!(
                "Incomplete download ({written} of {total_bytes} bytes)"
            ));
        }
        Ok(())
    })();

    if let Err(e) = result {
        let _ = std::fs::remove_file(&part_path);
        return Err(e);
    }

    std::fs::rename(&part_path, dest_path).map_err(|e| {
        let _ = std::fs::remove_file(&part_path);
        format!("Failed to finalize download: {e}")
    })?;
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
        // Pre-release must NOT be treated as newer than stable!
        assert!(!is_version_greater("2.0.0-beta.1", "2.0.0"));
        assert!(is_version_greater("2.0.0", "2.0.0-beta.1"));
        assert!(is_version_greater("2.0.0-beta.2", "2.0.0-beta.1"));
    }
}
