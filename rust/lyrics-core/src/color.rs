use std::io::Read;

use serde::Deserialize;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RgbaColor {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WaveformTheme {
    pub top: RgbaColor,
    pub bottom: RgbaColor,
    pub glow: RgbaColor,
    pub accent: RgbaColor,
}

impl Default for WaveformTheme {
    fn default() -> Self {
        Self {
            top: RgbaColor {
                r: 1.0,
                g: 0.88,
                b: 0.1,
                a: 1.0,
            },
            bottom: RgbaColor {
                r: 1.0,
                g: 0.50,
                b: 0.0,
                a: 1.0,
            },
            glow: RgbaColor {
                r: 1.0,
                g: 0.75,
                b: 0.1,
                a: 0.65,
            },
            accent: RgbaColor {
                r: 1.0,
                g: 0.95,
                b: 0.3,
                a: 1.0,
            },
        }
    }
}

fn rgb_to_hsb(r: f32, g: f32, b: f32) -> (f32, f32, f32) {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;
    let v = max;
    let s = if max > 0.0 { delta / max } else { 0.0 };
    let mut h = if delta <= 0.00001 {
        0.0
    } else if (max - r).abs() < 0.00001 {
        ((g - b) / delta) % 6.0
    } else if (max - g).abs() < 0.00001 {
        ((b - r) / delta) + 2.0
    } else {
        ((r - g) / delta) + 4.0
    };
    h /= 6.0;
    if h < 0.0 {
        h += 1.0;
    }
    (h, s, v)
}

fn hsb_to_rgb(h: f32, s: f32, v: f32) -> (f32, f32, f32) {
    if s <= 0.00001 {
        return (v, v, v);
    }
    let h6 = (h.rem_euclid(1.0)) * 6.0;
    let sector = h6.floor() as i32;
    let f = h6 - (sector as f32);
    let p = v * (1.0 - s);
    let q = v * (1.0 - s * f);
    let t = v * (1.0 - s * (1.0 - f));
    match sector {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    }
}

/// 12-hue-bucket HSB scoring matching v1.3.1 ColorExtractor.extractWaveformTheme(from:).
pub fn extract_waveform_theme_rgba(rgba: &[u8], width: usize, height: usize) -> WaveformTheme {
    let expected = width.saturating_mul(height).saturating_mul(4);
    if width == 0 || height == 0 || rgba.len() < expected {
        return WaveformTheme::default();
    }

    let mut bucket_scores = [0.0_f64; 12];
    let mut bucket_r = [0.0_f64; 12];
    let mut bucket_g = [0.0_f64; 12];
    let mut bucket_b = [0.0_f64; 12];

    for px in rgba[..expected].chunks_exact(4) {
        let a = (px[3] as f32) / 255.0;
        if a < 0.05 {
            continue;
        }
        let r = (px[0] as f32) / 255.0;
        let g = (px[1] as f32) / 255.0;
        let b = (px[2] as f32) / 255.0;
        let (h, s, v) = rgb_to_hsb(r, g, b);

        // Discard near-black, washed-out grays, and near-white
        if v < 0.12 || (s < 0.15 && v > 0.88) || s < 0.14 {
            continue;
        }

        let bucket = ((h * 12.0) as usize) % 12;
        let weight = (s * (1.0 - (v - 0.52).abs() * 0.4)) as f64;
        bucket_scores[bucket] += weight;
        bucket_r[bucket] += (r as f64) * weight;
        bucket_g[bucket] += (g as f64) * weight;
        bucket_b[bucket] += (b as f64) * weight;
    }

    let mut best_idx: Option<usize> = None;
    let mut best_score = 0.3_f64;
    for (idx, &score) in bucket_scores.iter().enumerate() {
        if score > best_score {
            best_score = score;
            best_idx = Some(idx);
        }
    }

    let Some(p_idx) = best_idx else {
        // Monochrome theme for B&W covers
        return WaveformTheme {
            top: RgbaColor {
                r: 1.0,
                g: 1.0,
                b: 1.0,
                a: 1.0,
            },
            bottom: RgbaColor {
                r: 0.70,
                g: 0.70,
                b: 0.70,
                a: 1.0,
            },
            glow: RgbaColor {
                r: 1.0,
                g: 1.0,
                b: 1.0,
                a: 0.65,
            },
            accent: RgbaColor {
                r: 0.95,
                g: 0.95,
                b: 0.95,
                a: 1.0,
            },
        };
    };

    let denom = bucket_scores[p_idx].max(1e-6);
    let avg_r = (bucket_r[p_idx] / denom) as f32;
    let avg_g = (bucket_g[p_idx] / denom) as f32;
    let avg_b = (bucket_b[p_idx] / denom) as f32;

    let (h, s, v) = rgb_to_hsb(avg_r, avg_g, avg_b);
    let vibrant_sat = (s * 1.25).clamp(0.55, 0.95);
    let top_b = (v * 1.7 + 0.22).clamp(0.68, 0.94);
    let bottom_b = (v * 1.35 + 0.08).clamp(0.42, 0.72);

    let (tr, tg, tb) = hsb_to_rgb(h, vibrant_sat * 0.88, top_b);
    let (br, bg, bb) = hsb_to_rgb(h, vibrant_sat, bottom_b);
    let (ar, ag, ab) = hsb_to_rgb(h, (vibrant_sat * 0.70).max(0.45), (top_b + 0.12).min(1.0));

    let top = RgbaColor {
        r: tr,
        g: tg,
        b: tb,
        a: 1.0,
    };
    let bottom = RgbaColor {
        r: br,
        g: bg,
        b: bb,
        a: 1.0,
    };
    let accent = RgbaColor {
        r: ar,
        g: ag,
        b: ab,
        a: 1.0,
    };
    let glow = RgbaColor {
        r: tr,
        g: tg,
        b: tb,
        a: 0.40,
    };
    WaveformTheme {
        top,
        bottom,
        glow,
        accent,
    }
}

pub fn sanitize_artwork_url(url_str: &str) -> Option<String> {
    let trimmed = url_str.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(hash) = trimmed.strip_prefix("spotify:image:") {
        if !hash.is_empty() {
            return Some(format!("https://i.scdn.co/image/{hash}"));
        }
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        return Some(trimmed.to_string());
    }
    None
}

pub fn download_url_bytes(url: &str, timeout_secs: u64, user_agent: &str) -> Option<Vec<u8>> {
    const MAX_BYTES: usize = 16 * 1024 * 1024;
    let secs = timeout_secs.clamp(1, 30);
    let resp = crate::shared_https_agent()
        .get(url)
        .timeout(std::time::Duration::from_secs(secs))
        .set("User-Agent", user_agent)
        .call()
        .ok()?;
    if resp.status() != 200 {
        return None;
    }
    let mut bytes = Vec::new();
    resp.into_reader()
        .take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        None
    } else {
        Some(bytes)
    }
}

#[derive(Deserialize)]
struct ITunesSearchResponse {
    results: Vec<ITunesTrackResult>,
}

#[derive(Deserialize)]
struct ITunesTrackResult {
    #[serde(rename = "trackName")]
    track_name: Option<String>,
    #[serde(rename = "artistName")]
    artist_name: Option<String>,
    #[serde(rename = "artworkUrl100")]
    artwork_url100: Option<String>,
}

fn clean_track_for_itunes(track: &str) -> String {
    let lower = track.to_lowercase();
    let mut cut = track.len();
    for needle in ["(feat", "(ft.", "[feat", "- remaster", "(remaster", "(official"] {
        if let Some(idx) = lower.find(needle) {
            if idx > 0 && idx < cut {
                cut = idx;
            }
        }
    }
    while cut > 0 && !track.is_char_boundary(cut) {
        cut -= 1;
    }
    let trimmed = track[..cut].trim();
    if trimmed.is_empty() {
        track.trim().to_string()
    } else {
        trimmed.to_string()
    }
}

pub fn fetch_itunes_artwork_bytes(track: &str, artist: &str) -> Option<Vec<u8>> {
    let cleaned = clean_track_for_itunes(track);
    let target_artist = crate::lyrics::simplify_for_match(artist);
    let target_track = crate::lyrics::simplify_for_match(&cleaned);
    if target_track.is_empty() {
        return None;
    }

    let query = if artist.trim().is_empty() {
        cleaned.clone()
    } else {
        format!("{} {}", artist.trim(), cleaned)
    };
    let encoded = urlencoding::encode(&query);
    let url = format!("https://itunes.apple.com/search?term={encoded}&entity=song&limit=8");
    let json_bytes = download_url_bytes(&url, 6, "LyricsMenuBar/2.0")?;
    let parsed: ITunesSearchResponse = serde_json::from_slice(&json_bytes).ok()?;

    for item in parsed.results {
        let Some(item_track_raw) = item.track_name.as_deref() else {
            continue;
        };
        let item_track = crate::lyrics::simplify_for_match(item_track_raw);
        if item_track.is_empty() {
            continue;
        }
        let track_match = item_track == target_track
            || item_track.contains(&target_track)
            || target_track.contains(&item_track);
        if !track_match {
            continue;
        }

        if !target_artist.is_empty() {
            let Some(item_artist_raw) = item.artist_name.as_deref() else {
                continue;
            };
            let item_artist = crate::lyrics::simplify_for_match(item_artist_raw);
            if item_artist.is_empty() {
                continue;
            }
            let artist_match = item_artist == target_artist
                || item_artist.contains(&target_artist)
                || target_artist.contains(&item_artist);
            if !artist_match {
                continue;
            }
        }

        if let Some(art100) = item.artwork_url100.as_deref() {
            let high_res = art100.replace("100x100bb", "600x600bb");
            if let Some(bytes) = download_url_bytes(&high_res, 8, "LyricsMenuBar/2.0") {
                return Some(bytes);
            }
            if high_res != art100 {
                if let Some(bytes) = download_url_bytes(art100, 8, "LyricsMenuBar/2.0") {
                    return Some(bytes);
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vibrant_blue_cover_extraction() {
        // 4x4 saturated blue cover
        let mut rgba = Vec::with_capacity(4 * 4 * 4);
        for _ in 0..16 {
            rgba.extend_from_slice(&[20, 90, 230, 255]);
        }
        let theme = extract_waveform_theme_rgba(&rgba, 4, 4);
        assert!(theme.top.b > theme.top.r, "Expected blue dominant: {:?}", theme.top);
        assert!((theme.glow.a - 0.40).abs() < 0.01);
    }

    #[test]
    fn test_grayscale_cover_fallback_monochrome() {
        let mut rgba = Vec::with_capacity(4 * 4 * 4);
        for _ in 0..16 {
            rgba.extend_from_slice(&[128, 128, 128, 255]);
        }
        let theme = extract_waveform_theme_rgba(&rgba, 4, 4);
        assert!((theme.top.r - 1.0).abs() < 0.01 && (theme.top.b - 1.0).abs() < 0.01);
    }

    #[test]
    fn test_sanitize_artwork_url() {
        assert_eq!(
            sanitize_artwork_url("spotify:image:ab67616d0000b273123"),
            Some("https://i.scdn.co/image/ab67616d0000b273123".to_string())
        );
        assert_eq!(sanitize_artwork_url("file:///tmp/x.png"), None);
        assert_eq!(
            sanitize_artwork_url("https://i.scdn.co/image/xyz"),
            Some("https://i.scdn.co/image/xyz".to_string())
        );
    }
}
