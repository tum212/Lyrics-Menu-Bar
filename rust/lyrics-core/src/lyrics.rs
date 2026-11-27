use std::collections::VecDeque;
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

use encoding_rs::WINDOWS_874;
use regex::Regex;
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LyricWord {
    pub id: u64,
    pub text: String,
    pub start_time: f64,
    pub end_time: f64,
    pub index: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LyricLine {
    pub id: u64,
    pub time: f64,
    pub end_time: f64,
    pub text: String,
    pub words: Vec<LyricWord>,
    pub is_background_vocal: bool,
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

fn next_uid() -> u64 {
    NEXT_ID.fetch_add(1, Ordering::Relaxed)
}

fn is_bg_vocal(text: &str) -> bool {
    let t = text.trim();
    (t.starts_with('(') && t.ends_with(')')) || (t.starts_with('[') && t.ends_with(']'))
}

// MARK: - Phonetic Syllable Weighting (100% Parity with v1.3.1 LyricTimingCalculator)

pub fn count_syllables(word: &str) -> usize {
    let cleaned = word
        .to_lowercase()
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_string();
    if cleaned.is_empty() || cleaned.chars().count() <= 3 {
        return 1;
    }

    let is_vowel = |c: char| matches!(c, 'a' | 'e' | 'i' | 'o' | 'u' | 'y');
    let mut count = 0usize;
    let mut prev_was_vowel = false;
    let chars: Vec<char> = cleaned.chars().collect();

    for &ch in &chars {
        let v = is_vowel(ch);
        if v && !prev_was_vowel {
            count += 1;
        }
        prev_was_vowel = v;
    }

    if cleaned.ends_with('e') && !cleaned.ends_with("le") && count > 1 && chars.len() >= 2 {
        let second_last = chars[chars.len() - 2];
        if !is_vowel(second_last) {
            count -= 1;
        }
    }
    count.max(1)
}

pub fn word_weight(word: &str, is_last_in_line: bool) -> f64 {
    let cleaned = word
        .to_lowercase()
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_string();
    let syllables = count_syllables(&cleaned);
    let char_len = cleaned.chars().count();

    let is_unstressed = matches!(
        cleaned.as_str(),
        "a" | "an"
            | "the"
            | "in"
            | "on"
            | "at"
            | "to"
            | "for"
            | "of"
            | "and"
            | "or"
            | "but"
            | "is"
            | "it"
            | "my"
            | "so"
            | "up"
            | "you"
            | "me"
            | "we"
            | "he"
            | "she"
            | "i"
    );

    let mut mult = if is_unstressed { 0.65 } else { 1.0 };
    if word.ends_with(',') || word.ends_with(';') || word.ends_with('-') || word.ends_with('—') {
        mult *= 1.30;
    } else if word.ends_with('?') || word.ends_with('!') {
        mult *= 1.25;
    }
    if is_last_in_line {
        mult *= 1.75;
    }

    let base = (syllables as f64) * 0.70 + (char_len as f64) * 0.08 + 0.22;
    base * mult
}

pub fn compute_word_timings(lines: Vec<LyricLine>, total_track_duration: f64) -> Vec<LyricLine> {
    if lines.is_empty() {
        return lines;
    }
    let len = lines.len();
    let mut out = Vec::with_capacity(len);

    for i in 0..len {
        let line = &lines[i];
        if !line.words.is_empty() && line.end_time > line.time {
            out.push(line.clone());
            continue;
        }

        let start_time = line.time;
        let tokens: Vec<&str> = line.text.split_whitespace().collect();
        if tokens.is_empty() {
            out.push(LyricLine {
                id: line.id,
                time: start_time,
                end_time: start_time + 1.0,
                text: line.text.clone(),
                words: Vec::new(),
                is_background_vocal: line.is_background_vocal,
            });
            continue;
        }

        let next_start = if i + 1 < len {
            lines[i + 1].time
        } else {
            let fallback = if total_track_duration > start_time {
                total_track_duration
            } else {
                start_time + 4.0
            };
            fallback.min(start_time + 6.0)
        };

        let raw_gap = (next_start - start_time).max(0.4);
        let total_syllables: usize = tokens.iter().map(|t| count_syllables(t)).sum();
        let est_singing = (total_syllables as f64) * 0.28 + 0.35;

        let vocal_duration = if raw_gap <= 1.8 {
            let breath = (raw_gap * 0.12).min(0.20);
            (raw_gap - breath).max(0.25)
        } else if raw_gap <= 6.0 {
            let breath = (raw_gap * 0.20).clamp(0.35, 1.2);
            let target = est_singing.max(raw_gap - breath);
            target.min(raw_gap - 0.2)
        } else {
            (est_singing * 1.25).max(4.5).min(raw_gap - 1.5)
        };

        let end_time = start_time + vocal_duration;
        let last_idx = tokens.len() - 1;
        let weights: Vec<f64> = tokens
            .iter()
            .enumerate()
            .map(|(idx, tok)| word_weight(tok, idx == last_idx))
            .collect();
        let total_weight: f64 = weights.iter().sum::<f64>().max(0.001);

        let mut words = Vec::with_capacity(tokens.len());
        let mut cur_start = start_time;
        for (idx, tok) in tokens.iter().enumerate() {
            let frac = weights[idx] / total_weight;
            let w_dur = (vocal_duration * frac).max(0.08);
            let w_end = if idx == last_idx {
                end_time
            } else {
                cur_start + w_dur
            };
            words.push(LyricWord {
                id: next_uid(),
                text: (*tok).to_string(),
                start_time: cur_start,
                end_time: w_end,
                index: idx,
            });
            cur_start = w_end;
        }

        out.push(LyricLine {
            id: line.id,
            time: start_time,
            end_time,
            text: line.text.clone(),
            words,
            is_background_vocal: line.is_background_vocal,
        });
    }
    out
}

// MARK: - Decoding (UTF-8 + Windows-874 Thai + Latin1)

pub fn decode_bytes(bytes: &[u8]) -> String {
    let slice = if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        &bytes[3..]
    } else {
        bytes
    };
    if let Ok(s) = std::str::from_utf8(slice) {
        return s.replace('\u{FEFF}', "");
    }
    let (decoded, _, had_errors) = WINDOWS_874.decode(slice);
    if !had_errors {
        return decoded.into_owned();
    }
    slice.iter().map(|&b| b as char).collect()
}

// MARK: - Parsers (LRC, eLRC, TTML, Plain)

fn offset_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)\[offset:\s*([+-]?\d+)\]").unwrap())
}

fn tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\[(\d+):(\d+(?:\.\d+)?)\]").unwrap())
}

fn html_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<[^>]+>").unwrap())
}

fn elrc_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?:<|\(|\[)(\d+):(\d+(?:\.\d+)?)(?:>|\)|\])([^<\(\[]*)").unwrap())
}

fn ttml_p_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?s)<p\s+begin="([^"]+)"\s+end="([^"]+)"[^>]*>(.*?)</p>"#).unwrap())
}

fn ttml_span_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<span\s+begin="([^"]+)"\s+end="([^"]+)"[^>]*>([^<]*)</span>"#).unwrap())
}

fn parse_elrc_line(content: &str) -> Option<(String, Vec<LyricWord>)> {
    let caps: Vec<_> = elrc_regex().captures_iter(content).collect();
    if caps.is_empty() {
        return None;
    }

    let mut words: Vec<LyricWord> = Vec::new();
    let mut full_text = String::new();

    for i in 0..caps.len() {
        let cap = &caps[i];
        let Ok(min) = cap[1].parse::<f64>() else {
            continue;
        };
        let Ok(sec) = cap[2].parse::<f64>() else {
            continue;
        };
        let word_start = min * 60.0 + sec;
        let raw_token = &cap[3];
        let trimmed = raw_token.trim();
        if trimmed.is_empty() {
            continue;
        }

        let next_word_start = if i + 1 < caps.len() {
            let nm = caps[i + 1][1].parse::<f64>().unwrap_or(0.0);
            let ns = caps[i + 1][2].parse::<f64>().unwrap_or(0.0);
            nm * 60.0 + ns
        } else {
            word_start + 0.8
        };

        let is_continuation =
            !words.is_empty() && !raw_token.starts_with(' ') && !full_text.ends_with(' ');
        if is_continuation {
            if let Some(last) = words.last_mut() {
                last.text.push_str(trimmed);
                last.end_time = last.end_time.max((word_start + 0.1).max(next_word_start));
            }
        } else {
            let idx = words.len();
            words.push(LyricWord {
                id: next_uid(),
                text: trimmed.to_string(),
                start_time: word_start,
                end_time: (word_start + 0.1).max(next_word_start),
                index: idx,
            });
        }
        full_text.push_str(raw_token);
    }

    if words.is_empty() {
        None
    } else {
        Some((full_text.trim().to_string(), words))
    }
}

fn parse_timestamp(s: &str) -> Option<f64> {
    let t = s.trim();
    if let Some(ms_str) = t.strip_suffix("ms") {
        return ms_str.parse::<f64>().ok().map(|v| v / 1000.0);
    }
    if let Some(sec_str) = t.strip_suffix('s') {
        return sec_str.parse::<f64>().ok();
    }
    let parts: Vec<&str> = t.split(':').collect();
    match parts.len() {
        3 => {
            let h = parts[0].parse::<f64>().ok()?;
            let m = parts[1].parse::<f64>().ok()?;
            let s = parts[2].parse::<f64>().ok()?;
            Some(h * 3600.0 + m * 60.0 + s)
        }
        2 => {
            let m = parts[0].parse::<f64>().ok()?;
            let s = parts[1].parse::<f64>().ok()?;
            Some(m * 60.0 + s)
        }
        _ => t.parse::<f64>().ok(),
    }
}

pub fn parse_ttml(ttml: &str) -> Vec<LyricLine> {
    let mut lines = Vec::new();
    for cap in ttml_p_regex().captures_iter(ttml) {
        let Some(start_time) = parse_timestamp(&cap[1]) else {
            continue;
        };
        let Some(end_time) = parse_timestamp(&cap[2]) else {
            continue;
        };
        let inner = &cap[3];

        let mut words = Vec::new();
        let mut full_text = String::new();
        for (idx, sm) in ttml_span_regex().captures_iter(inner).enumerate() {
            if let (Some(ws), Some(we)) = (parse_timestamp(&sm[1]), parse_timestamp(&sm[2])) {
                let wt = sm[3].trim();
                if !wt.is_empty() {
                    if !full_text.is_empty() {
                        full_text.push(' ');
                    }
                    full_text.push_str(wt);
                    words.push(LyricWord {
                        id: next_uid(),
                        text: wt.to_string(),
                        start_time: ws,
                        end_time: we,
                        index: idx,
                    });
                }
            }
        }
        if !words.is_empty() {
            let bg = is_bg_vocal(&full_text);
            lines.push(LyricLine {
                id: next_uid(),
                time: start_time,
                end_time,
                text: full_text,
                words,
                is_background_vocal: bg,
            });
            continue;
        }

        let clean = html_tag_regex().replace_all(inner, "").trim().to_string();
        if !clean.is_empty() {
            let bg = is_bg_vocal(&clean);
            lines.push(LyricLine {
                id: next_uid(),
                time: start_time,
                end_time,
                text: clean,
                words: Vec::new(),
                is_background_vocal: bg,
            });
        }
    }

    lines.sort_by(|a, b| a.time.total_cmp(&b.time));
    compute_word_timings(lines, 0.0)
}

pub fn parse_lrc(lrc: &str) -> Vec<LyricLine> {
    let clean_lrc = lrc.replace('\u{FEFF}', "");
    if clean_lrc.contains("<tt") || clean_lrc.contains("<p begin=") {
        let ttml = parse_ttml(&clean_lrc);
        if !ttml.is_empty() {
            return ttml;
        }
    }

    let time_offset: f64 = offset_regex()
        .captures(&clean_lrc)
        .and_then(|c| c[1].parse::<f64>().ok())
        .map(|ms| ms / 1000.0)
        .unwrap_or(0.0);

    let mut result = Vec::new();
    for raw_line in clean_lrc.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with('[')
            && !trimmed.as_bytes().get(1).is_some_and(|b| b.is_ascii_digit())
        {
            continue;
        }

        let matches: Vec<_> = tag_regex().captures_iter(trimmed).collect();
        let Some(last) = matches.last() else {
            continue;
        };
        let last_end = last.get(0).map(|m| m.end()).unwrap_or(0);
        let line_content = trimmed[last_end..].trim();

        let elrc_data = parse_elrc_line(line_content);
        let clean_text = elrc_data
            .as_ref()
            .map(|(t, _)| t.clone())
            .unwrap_or_else(|| html_tag_regex().replace_all(line_content, "").trim().to_string());
        let bg = is_bg_vocal(&clean_text);

        for m in &matches {
            let Ok(min) = m[1].parse::<f64>() else {
                continue;
            };
            let Ok(sec) = m[2].parse::<f64>() else {
                continue;
            };
            let line_time = (min * 60.0 + sec + time_offset).max(0.0);
            if let Some((_, ref base_words)) = elrc_data {
                if !base_words.is_empty() {
                    let adjusted: Vec<LyricWord> = base_words
                        .iter()
                        .map(|w| LyricWord {
                            id: next_uid(),
                            text: w.text.clone(),
                            start_time: (w.start_time + time_offset).max(0.0),
                            end_time: (w.end_time + time_offset).max(0.0),
                            index: w.index,
                        })
                        .collect();
                    let line_end = adjusted.last().map(|w| w.end_time).unwrap_or(line_time + 3.0);
                    result.push(LyricLine {
                        id: next_uid(),
                        time: line_time,
                        end_time: line_end,
                        text: clean_text.clone(),
                        words: adjusted,
                        is_background_vocal: bg,
                    });
                    continue;
                }
            }
            result.push(LyricLine {
                id: next_uid(),
                time: line_time,
                end_time: 0.0,
                text: clean_text.clone(),
                words: Vec::new(),
                is_background_vocal: bg,
            });
        }
    }

    result.sort_by(|a, b| a.time.total_cmp(&b.time));
    compute_word_timings(result, 0.0)
}

pub fn parse_plain(text: &str) -> Vec<LyricLine> {
    let mut body = text.to_string();
    if body.starts_with("Paroles de la chanson") {
        for sep in ["\r\n\n", "\n\n"] {
            if let Some(pos) = body.find(sep) {
                body = body[pos + sep.len()..].to_string();
                break;
            }
        }
    }
    body.lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .map(|l| LyricLine {
            id: next_uid(),
            time: 0.0,
            end_time: 0.0,
            text: l.to_string(),
            words: Vec::new(),
            is_background_vocal: is_bg_vocal(l),
        })
        .collect()
}

// MARK: - Fuzzy Track Matching

pub fn simplify_for_match(s: &str) -> String {
    let stripped: String = s
        .nfd()
        .filter(|c| !unicode_normalization::char::is_combining_mark(*c))
        .collect();
    stripped
        .to_lowercase()
        .replace(['-', '(', ')', '.'], " ")
        .replace(['\'', '"'], "")
        .trim()
        .to_string()
}

pub fn is_matching_track(
    track_name: Option<&str>,
    artist_name: Option<&str>,
    expected_track: &str,
    expected_artist: &str,
) -> bool {
    let (Some(t), Some(a)) = (track_name, artist_name) else {
        return false;
    };
    let st = simplify_for_match(t);
    let sa = simplify_for_match(a);
    let s_exp_t = simplify_for_match(expected_track);
    let s_exp_a = simplify_for_match(expected_artist);
    if st.is_empty() || sa.is_empty() || s_exp_t.is_empty() || s_exp_a.is_empty() {
        return false;
    }
    let artist_matches = sa == s_exp_a || sa.contains(&s_exp_a) || s_exp_a.contains(&sa);
    let track_matches = st == s_exp_t || st.contains(&s_exp_t) || s_exp_t.contains(&st);
    artist_matches && track_matches
}

// MARK: - LRU Cache & Multi-Source Concurrent Fetcher

struct LruLyricsCache {
    cap: usize,
    entries: VecDeque<(String, Vec<LyricLine>)>,
}

impl LruLyricsCache {
    fn new(cap: usize) -> Self {
        Self {
            cap,
            entries: VecDeque::with_capacity(cap),
        }
    }

    fn get(&mut self, key: &str) -> Option<Vec<LyricLine>> {
        let pos = self.entries.iter().position(|(k, _)| k == key)?;
        let item = self.entries.remove(pos)?;
        let val = item.1.clone();
        self.entries.push_back(item);
        Some(val)
    }

    fn insert(&mut self, key: String, val: Vec<LyricLine>) {
        if let Some(pos) = self.entries.iter().position(|(k, _)| k == &key) {
            self.entries.remove(pos);
        } else if self.entries.len() >= self.cap {
            self.entries.pop_front();
        }
        self.entries.push_back((key, val));
    }
}

#[derive(Clone)]
pub struct LyricsEndpoints {
    pub lrclib_search: String,
    pub lrclib_get: String,
    pub lyrics_ovh: String,
}

impl Default for LyricsEndpoints {
    fn default() -> Self {
        Self {
            lrclib_search: "https://lrclib.net/api/search".to_string(),
            lrclib_get: "https://lrclib.net/api/get".to_string(),
            lyrics_ovh: "https://api.lyrics.ovh/v1".to_string(),
        }
    }
}

#[derive(Deserialize)]
struct LrcResult {
    #[serde(rename = "trackName")]
    track_name: Option<String>,
    #[serde(rename = "artistName")]
    artist_name: Option<String>,
    #[serde(rename = "syncedLyrics")]
    synced_lyrics: Option<String>,
    #[serde(rename = "plainLyrics")]
    plain_lyrics: Option<String>,
}

#[derive(Deserialize)]
struct OvhResult {
    lyrics: Option<String>,
}

fn fetch_url_text(url: &str) -> Option<String> {
    let agent = crate::build_https_agent(12, 15);
    let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
    let resp = agent.get(url).set("User-Agent", ua).call().ok()?;
    if resp.status() != 200 {
        return None;
    }
    let mut bytes = Vec::new();
    resp.into_reader()
        .take(4 * 1024 * 1024)
        .read_to_end(&mut bytes)
        .ok()?;
    Some(decode_bytes(&bytes))
}

fn lrclib_search(
    endpoint: &str,
    query: &str,
    expected_track: &str,
    expected_artist: &str,
) -> Vec<LyricLine> {
    let encoded = urlencoding::encode(query);
    let url = format!("{endpoint}?q={encoded}");
    let Some(text) = fetch_url_text(&url) else {
        return Vec::new();
    };
    let Ok(results) = serde_json::from_str::<Vec<LrcResult>>(&text) else {
        return Vec::new();
    };
    let matched: Vec<LrcResult> = results
        .into_iter()
        .filter(|r| {
            is_matching_track(
                r.track_name.as_deref(),
                r.artist_name.as_deref(),
                expected_track,
                expected_artist,
            )
        })
        .collect();
    if let Some(synced) = matched
        .iter()
        .find_map(|r| r.synced_lyrics.as_deref().filter(|s| !s.is_empty()))
    {
        return parse_lrc(synced);
    }
    if let Some(plain) = matched
        .iter()
        .find_map(|r| r.plain_lyrics.as_deref().filter(|s| !s.is_empty()))
    {
        return parse_plain(plain);
    }
    Vec::new()
}

fn lrclib_get(endpoint: &str, track: &str, artist: &str, album: &str) -> Vec<LyricLine> {
    let url = format!(
        "{endpoint}?track_name={}&artist_name={}&album_name={}",
        urlencoding::encode(track),
        urlencoding::encode(artist),
        urlencoding::encode(album),
    );
    let Some(text) = fetch_url_text(&url) else {
        return Vec::new();
    };
    let Ok(res) = serde_json::from_str::<LrcResult>(&text) else {
        return Vec::new();
    };
    if !is_matching_track(
        res.track_name.as_deref(),
        res.artist_name.as_deref(),
        track,
        artist,
    ) {
        return Vec::new();
    }
    if let Some(synced) = res.synced_lyrics.as_deref().filter(|s| !s.is_empty()) {
        return parse_lrc(synced);
    }
    if let Some(plain) = res.plain_lyrics.as_deref().filter(|s| !s.is_empty()) {
        return parse_plain(plain);
    }
    Vec::new()
}

fn ovh_fetch(endpoint: &str, track: &str, artist: &str) -> Vec<LyricLine> {
    let url = format!(
        "{endpoint}/{}/{}",
        urlencoding::encode(artist),
        urlencoding::encode(track),
    );
    let Some(text) = fetch_url_text(&url) else {
        return Vec::new();
    };
    let Ok(res) = serde_json::from_str::<OvhResult>(&text) else {
        return Vec::new();
    };
    res.lyrics
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(parse_plain)
        .unwrap_or_default()
}

pub type LyricsReadyCallback = extern "C" fn(ctx: usize, request_id: u64);

pub struct LyricsEngine {
    pub current_lines: Mutex<Arc<Vec<LyricLine>>>,
    pub is_loading: AtomicBool,
    request_id: AtomicU64,
    last_query: Mutex<String>,
    cache: Mutex<LruLyricsCache>,
    pub endpoints: Mutex<LyricsEndpoints>,
}

impl LyricsEngine {
    pub fn new() -> Self {
        Self {
            current_lines: Mutex::new(Arc::new(Vec::new())),
            is_loading: AtomicBool::new(false),
            request_id: AtomicU64::new(0),
            last_query: Mutex::new(String::new()),
            cache: Mutex::new(LruLyricsCache::new(100)),
            endpoints: Mutex::new(LyricsEndpoints::default()),
        }
    }

    pub fn clear(&self) {
        self.request_id.fetch_add(1, Ordering::AcqRel);
        self.is_loading.store(false, Ordering::Release);
        if let Ok(mut q) = self.last_query.lock() {
            q.clear();
        }
        if let Ok(mut lines) = self.current_lines.lock() {
            *lines = Arc::new(Vec::new());
        }
    }

    pub fn set_endpoints(&self, lrclib_search: &str, lrclib_get: &str, lyrics_ovh: &str) {
        if let Ok(mut ep) = self.endpoints.lock() {
            if !lrclib_search.is_empty() {
                ep.lrclib_search = lrclib_search.to_string();
            }
            if !lrclib_get.is_empty() {
                ep.lrclib_get = lrclib_get.to_string();
            }
            if !lyrics_ovh.is_empty() {
                ep.lyrics_ovh = lyrics_ovh.to_string();
            }
        }
    }

    pub fn snapshot(&self) -> Arc<Vec<LyricLine>> {
        self.current_lines
            .lock()
            .map(|g| g.clone())
            .unwrap_or_else(|_| Arc::new(Vec::new()))
    }

    /// Returns true on synchronous cache hit (caller can read lines right away).
    /// Returns false if async network race was dispatched.
    pub fn fetch_lyrics(
        self: &Arc<Self>,
        track_name: &str,
        artist_name: &str,
        album_name: &str,
        ctx: usize,
        callback: LyricsReadyCallback,
    ) -> bool {
        if track_name.is_empty() || artist_name.is_empty() {
            return false;
        }
        let query_key = format!("{track_name}-{artist_name}-{album_name}");
        if let Ok(mut last_q) = self.last_query.lock() {
            if *last_q == query_key {
                return false;
            }
            *last_q = query_key.clone();
        }

        let my_id = self.request_id.fetch_add(1, Ordering::AcqRel) + 1;

        if let Ok(mut cache) = self.cache.lock() {
            if let Some(hit) = cache.get(&query_key) {
                if let Ok(mut lines) = self.current_lines.lock() {
                    *lines = Arc::new(hit);
                }
                self.is_loading.store(false, Ordering::Release);
                return true;
            }
        }

        if let Ok(mut lines) = self.current_lines.lock() {
            *lines = Arc::new(Vec::new());
        }
        self.is_loading.store(true, Ordering::Release);

        let mut clean = track_name.to_string();
        if let Some(idx) = clean.find(" - ") {
            clean.truncate(idx);
        }
        if let Some(idx) = clean.find(" (") {
            clean.truncate(idx);
        }
        let clean_track = clean.trim().to_string();
        let orig_track = track_name.to_string();
        let artist = artist_name.to_string();
        let album = album_name.to_string();
        let ep = self
            .endpoints
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        let engine = self.clone();

        let _ = thread::Builder::new()
            .name("lyrics-fetch".into())
            .spawn(move || {
                // Phase 1: Race 3 LRCLib queries concurrently
                let (tx, rx) = std::sync::mpsc::channel::<(usize, Vec<LyricLine>)>();

                {
                    let tx0 = tx.clone();
                    let ep_get = ep.lrclib_get.clone();
                    let ct = clean_track.clone();
                    let ar = artist.clone();
                    let al = album.clone();
                    let _ = thread::spawn(move || {
                        let res = lrclib_get(&ep_get, &ct, &ar, &al);
                        let _ = tx0.send((0, res));
                    });
                }
                {
                    let tx1 = tx.clone();
                    let ep_s = ep.lrclib_search.clone();
                    let ct = clean_track.clone();
                    let ar = artist.clone();
                    let _ = thread::spawn(move || {
                        let q = format!("{ct} {ar}");
                        let res = lrclib_search(&ep_s, &q, &ct, &ar);
                        let _ = tx1.send((1, res));
                    });
                }
                {
                    let tx2 = tx;
                    let ep_s = ep.lrclib_search.clone();
                    let ot = orig_track.clone();
                    let ar = artist.clone();
                    let _ = thread::spawn(move || {
                        let q = format!("{ot} {ar}");
                        let res = lrclib_search(&ep_s, &q, &ot, &ar);
                        let _ = tx2.send((2, res));
                    });
                }

                let mut winner: Option<Vec<LyricLine>> = None;
                let mut collected: [Option<Vec<LyricLine>>; 3] = [None, None, None];
                for _ in 0..3 {
                    if engine.request_id.load(Ordering::Acquire) != my_id {
                        return;
                    }
                    let Ok((idx, res)) = rx.recv() else { break };
                    if !res.is_empty() {
                        let is_synced = res.len() > 1 && res.last().is_some_and(|l| l.time > 0.0);
                        if is_synced {
                            winner = Some(res);
                            break;
                        }
                        if idx < 3 {
                            collected[idx] = Some(res);
                        }
                    }
                }
                if winner.is_none() {
                    winner = collected
                        .into_iter()
                        .flatten()
                        .find(|v| !v.is_empty());
                }

                if engine.request_id.load(Ordering::Acquire) != my_id {
                    return;
                }

                if let Some(lines) = winner {
                    if let Ok(mut c) = engine.cache.lock() {
                        c.insert(query_key, lines.clone());
                    }
                    if let Ok(mut cur) = engine.current_lines.lock() {
                        *cur = Arc::new(lines);
                    }
                    engine.is_loading.store(false, Ordering::Release);
                    callback(ctx, my_id);
                    return;
                }

                // Phase 2: Race 2 OVH requests concurrently
                let (otx, orx) = std::sync::mpsc::channel::<Vec<LyricLine>>();
                {
                    let tx0 = otx.clone();
                    let ep_o = ep.lyrics_ovh.clone();
                    let ct = clean_track;
                    let ar = artist.clone();
                    let _ = thread::spawn(move || {
                        let _ = tx0.send(ovh_fetch(&ep_o, &ct, &ar));
                    });
                }
                {
                    let tx1 = otx;
                    let ep_o = ep.lyrics_ovh;
                    let ot = orig_track;
                    let ar = artist;
                    let _ = thread::spawn(move || {
                        let _ = tx1.send(ovh_fetch(&ep_o, &ot, &ar));
                    });
                }

                let mut final_ovh = Vec::new();
                for _ in 0..2 {
                    if engine.request_id.load(Ordering::Acquire) != my_id {
                        return;
                    }
                    if let Ok(res) = orx.recv() {
                        if !res.is_empty() {
                            final_ovh = res;
                            break;
                        }
                    }
                }

                if engine.request_id.load(Ordering::Acquire) != my_id {
                    return;
                }
                if let Ok(mut c) = engine.cache.lock() {
                    c.insert(query_key, final_ovh.clone());
                }
                if let Ok(mut cur) = engine.current_lines.lock() {
                    *cur = Arc::new(final_ovh);
                }
                engine.is_loading.store(false, Ordering::Release);
                callback(ctx, my_id);
            });

        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_lrc_offset_and_multitag() {
        let lrc = "\u{FEFF}[ar:Tester]\n[offset:500]\n[00:01.00][00:05.00]Hello world\n[00:08.00](ooh)\n";
        let lines = parse_lrc(lrc);
        assert_eq!(lines.len(), 3);
        assert!((lines[0].time - 1.5).abs() < 0.01);
        assert!((lines[1].time - 5.5).abs() < 0.01);
        assert!(lines[2].is_background_vocal);
        assert_eq!(lines[0].words.len(), 2);
        assert!(lines[0].words[0].start_time < lines[0].words[0].end_time);
    }

    #[test]
    fn test_parse_elrc_syllable_continuation() {
        let lrc = "[00:10.00]<00:10.00>beau<00:10.25>ti<00:10.50>ful <00:10.80>day\n";
        let lines = parse_lrc(lrc);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[0].text, "beautiful");
        assert_eq!(lines[0].words[1].text, "day");
        assert!(lines[0].words[0].end_time >= 10.7);
    }

    #[test]
    fn test_parse_ttml() {
        let ttml = r#"<tt><body><p begin="1000ms" end="4.5s"><span begin="1000ms" end="2.0s">One</span><span begin="2.0s" end="4.5s">Two</span></p></body></tt>"#;
        let lines = parse_ttml(ttml);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text, "One Two");
        assert_eq!(lines[0].words.len(), 2);
        assert!((lines[0].time - 1.0).abs() < 0.01);
        assert!((lines[0].end_time - 4.5).abs() < 0.01);
    }

    #[test]
    fn test_plain_ovh_strip_and_thai_decode() {
        let plain = "Paroles de la chanson Test par Artist\n\nLine 1\nLine 2\n";
        let lines = parse_plain(plain);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text, "Line 1");

        // Windows-874 for "ก" is 0xA1
        let decoded = decode_bytes(&[0xA1]);
        assert_eq!(decoded, "ก");
    }

    #[test]
    fn test_fuzzy_match_diacritics() {
        assert!(is_matching_track(
            Some("Déjà Vu (Deluxe)"),
            Some("Beyoncé"),
            "Deja Vu",
            "Beyonce"
        ));
    }
}
