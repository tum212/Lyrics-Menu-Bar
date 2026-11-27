use std::collections::VecDeque;
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

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

// MARK: - Phonetic Syllable Weighting (100% Parity + Thai/CJK Aware)

pub fn count_syllables(word: &str) -> usize {
    let cleaned: String = word
        .to_lowercase()
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_string();
    if cleaned.is_empty() {
        return 1;
    }

    // Non-ASCII heuristic (Thai/CJK/Korean): estimate syllables from base (non-combining) characters
    if !cleaned.is_ascii() {
        let base_chars = cleaned
            .chars()
            .filter(|c| !unicode_normalization::char::is_combining_mark(*c))
            .count();
        return (base_chars / 2).max(1);
    }

    if cleaned.len() <= 3 {
        return 1;
    }

    let is_vowel = |c: char| matches!(c, 'a' | 'e' | 'i' | 'o' | 'u' | 'y');
    let mut count = 0usize;
    let mut prev_was_vowel = false;
    let bytes = cleaned.as_bytes();

    for &b in bytes {
        let v = is_vowel(b as char);
        if v && !prev_was_vowel {
            count += 1;
        }
        prev_was_vowel = v;
    }

    if cleaned.ends_with('e')
        && !cleaned.ends_with("le")
        && !cleaned.ends_with("ee")
        && !cleaned.ends_with("ye")
        && count > 1
    {
        count -= 1;
    }
    if cleaned.ends_with("ed") && !cleaned.ends_with("ted") && !cleaned.ends_with("ded") && count > 1
    {
        count -= 1;
    }

    count.max(1)
}

fn word_weight(word: &str, is_last_in_line: bool) -> f64 {
    let syls = count_syllables(word) as f64;
    let mut weight = syls;
    let lower = word.to_lowercase();
    let trimmed = lower.trim_matches(|c: char| !c.is_alphanumeric());

    let fast_words = [
        "a", "an", "the", "to", "of", "in", "on", "at", "by", "for", "and", "or", "but", "is",
        "am", "are", "was", "it", "i", "im", "i'm", "u", "ur", "my", "me", "we", "he", "she", "ya",
        "da", "de", "la",
    ];
    if fast_words.contains(&trimmed) {
        weight *= 0.55;
    }

    if word.ends_with(',') || word.ends_with(';') || word.ends_with(':') {
        weight += 0.85;
    } else if word.ends_with('.') || word.ends_with('!') || word.ends_with('?') {
        weight += 1.25;
    } else if word.ends_with("...") || word.ends_with('\u{2014}') || word.ends_with('-') {
        weight += 1.4;
    }

    if is_last_in_line {
        weight += 0.6;
    }

    let char_count = trimmed.chars().count();
    if char_count > 6 {
        weight += ((char_count - 6) as f64) * 0.12;
    }
    weight.max(0.35)
}

pub fn compute_word_timings(lines: Vec<LyricLine>, total_duration: f64) -> Vec<LyricLine> {
    if lines.is_empty() {
        return lines;
    }
    let is_unsynced = lines
        .last()
        .is_some_and(|l| l.time == 0.0 && l.end_time == 0.0);
    if is_unsynced {
        return lines;
    }

    let mut out = Vec::with_capacity(lines.len());
    for i in 0..lines.len() {
        let line = &lines[i];
        if !line.words.is_empty() {
            let computed_end = if line.end_time > line.time {
                line.end_time
            } else if i + 1 < lines.len() {
                lines[i + 1].time
            } else {
                line.time + 5.0
            };
            let mut copy = line.clone();
            copy.end_time = computed_end;
            out.push(copy);
            continue;
        }

        let tokens: Vec<&str> = line.text.split_whitespace().collect();
        if tokens.is_empty() {
            out.push(line.clone());
            continue;
        }

        let start_time = line.time;
        let next_start = if i + 1 < lines.len() {
            lines[i + 1].time
        } else if total_duration > start_time {
            total_duration
        } else {
            start_time + 5.0
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

        // Enforce monotonic non-inverted timestamps even for rapid multi-word lines
        let min_word = (vocal_duration / (tokens.len() as f64)).min(0.08);
        let raw_durs: Vec<f64> = weights
            .iter()
            .map(|&w| (vocal_duration * (w / total_weight)).max(min_word))
            .collect();
        let dur_sum: f64 = raw_durs.iter().sum::<f64>().max(0.001);
        let scale = vocal_duration / dur_sum;

        let mut words = Vec::with_capacity(tokens.len());
        let mut cur_start = start_time;
        for (idx, tok) in tokens.iter().enumerate() {
            let w_end = if idx == last_idx {
                end_time
            } else {
                (cur_start + raw_durs[idx] * scale).min(end_time)
            };
            words.push(LyricWord {
                id: next_uid(),
                text: (*tok).to_string(),
                start_time: cur_start,
                end_time: w_end.max(cur_start),
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

fn decode_xml_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    s.replace("&amp;", "&")
        .replace("&apos;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

// MARK: - Parsers (LRC, eLRC, TTML, Plain)

fn offset_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)\[offset:\s*([+-]?\d+)\]").unwrap())
}

fn leading_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^\s*\[(\d+):(\d+(?:\.\d+)?)\]").unwrap())
}

fn html_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<[^>]+>").unwrap())
}

/// Matched-delimiter inline eLRC timestamp finder: `<mm:ss.xx>`, `(mm:ss.xx)`, or `[mm:ss.xx]`
fn inline_elrc_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"<(\d+):(\d+(?:\.\d+)?)>|\((\d+):(\d+(?:\.\d+)?)\)|\[(\d+):(\d+(?:\.\d+)?)\]")
            .unwrap()
    })
}

fn ttml_p_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?s)<p\b([^>]*)>(.*?)</p>"#).unwrap())
}

fn ttml_span_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?s)<span\b([^>]*)>([^<]*)</span>"#).unwrap())
}

fn extract_xml_attr<'a>(attrs: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("{key}=\"");
    let pos = attrs.find(&needle)?;
    let rest = &attrs[pos + needle.len()..];
    let end = rest.find('"')?;
    Some(&rest[..end])
}

fn parse_elrc_line(content: &str, line_start: f64) -> Option<(String, Vec<LyricWord>)> {
    let re = inline_elrc_tag_regex();
    let mut tags: Vec<(usize, usize, f64)> = Vec::new();
    for cap in re.captures_iter(content) {
        let Some(full) = cap.get(0) else { continue };
        let (min_s, sec_s) = if let (Some(m), Some(s)) = (cap.get(1), cap.get(2)) {
            (m.as_str(), s.as_str())
        } else if let (Some(m), Some(s)) = (cap.get(3), cap.get(4)) {
            (m.as_str(), s.as_str())
        } else if let (Some(m), Some(s)) = (cap.get(5), cap.get(6)) {
            (m.as_str(), s.as_str())
        } else {
            continue;
        };
        let (Ok(min), Ok(sec)) = (min_s.parse::<f64>(), sec_s.parse::<f64>()) else {
            continue;
        };
        if min.is_finite() && sec.is_finite() {
            tags.push((full.start(), full.end(), min * 60.0 + sec));
        }
    }
    if tags.is_empty() {
        return None;
    }

    let mut words: Vec<LyricWord> = Vec::new();
    let mut full_text = String::new();

    // Preserve any leading text before the first inline timestamp
    if tags[0].0 > 0 {
        let prefix = &content[..tags[0].0];
        let trimmed = prefix.trim();
        if !trimmed.is_empty() {
            let end_t = tags[0].2.max(line_start + 0.1);
            words.push(LyricWord {
                id: next_uid(),
                text: trimmed.to_string(),
                start_time: line_start,
                end_time: end_t,
                index: 0,
            });
            full_text.push_str(prefix);
        }
    }

    for i in 0..tags.len() {
        let (_, tag_end, word_start) = tags[i];
        let next_start_byte = if i + 1 < tags.len() {
            tags[i + 1].0
        } else {
            content.len()
        };
        let raw_token = &content[tag_end..next_start_byte];
        let trimmed = raw_token.trim();
        if trimmed.is_empty() {
            full_text.push_str(raw_token);
            continue;
        }
        let next_word_start = if i + 1 < tags.len() {
            tags[i + 1].2
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
    let val = if let Some(ms_str) = t.strip_suffix("ms") {
        ms_str.parse::<f64>().ok().map(|v| v / 1000.0)
    } else if let Some(sec_str) = t.strip_suffix('s') {
        sec_str.parse::<f64>().ok()
    } else {
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
    }?;
    if val.is_finite() && val >= 0.0 {
        Some(val)
    } else {
        None
    }
}

pub fn parse_ttml(ttml: &str) -> Vec<LyricLine> {
    let mut lines = Vec::new();
    for cap in ttml_p_tag_regex().captures_iter(ttml) {
        let attrs = &cap[1];
        let Some(begin_s) = extract_xml_attr(attrs, "begin") else {
            continue;
        };
        let Some(end_s) = extract_xml_attr(attrs, "end") else {
            continue;
        };
        let (Some(start_time), Some(end_time)) = (parse_timestamp(begin_s), parse_timestamp(end_s))
        else {
            continue;
        };
        let inner = &cap[2];

        let mut words = Vec::new();
        let mut full_text = String::new();
        for sm in ttml_span_tag_regex().captures_iter(inner) {
            let s_attrs = &sm[1];
            let (Some(bs), Some(es)) = (
                extract_xml_attr(s_attrs, "begin"),
                extract_xml_attr(s_attrs, "end"),
            ) else {
                continue;
            };
            if let (Some(ws), Some(we)) = (parse_timestamp(bs), parse_timestamp(es)) {
                let decoded = decode_xml_entities(&sm[2]);
                let wt = decoded.trim();
                if !wt.is_empty() {
                    if !full_text.is_empty() {
                        full_text.push(' ');
                    }
                    full_text.push_str(wt);
                    let idx = words.len();
                    words.push(LyricWord {
                        id: next_uid(),
                        text: wt.to_string(),
                        start_time: ws,
                        end_time: we.max(ws),
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
                end_time: end_time.max(start_time),
                text: full_text,
                words,
                is_background_vocal: bg,
            });
            continue;
        }

        let stripped = html_tag_regex().replace_all(inner, "");
        let clean = decode_xml_entities(stripped.trim());
        if !clean.is_empty() {
            let bg = is_bg_vocal(&clean);
            lines.push(LyricLine {
                id: next_uid(),
                time: start_time,
                end_time: end_time.max(start_time),
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
    if clean_lrc.contains("<tt") || clean_lrc.contains("<p ") {
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
    let lead_re = leading_tag_regex();
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

        // Parse ONLY consecutive leading [mm:ss.xx] line tags so inline [mm:ss.xx] eLRC word tags stay intact
        let mut line_times: Vec<f64> = Vec::new();
        let mut rest = trimmed;
        while let Some(cap) = lead_re.captures(rest) {
            let Some(m0) = cap.get(0) else { break };
            if let (Ok(min), Ok(sec)) = (cap[1].parse::<f64>(), cap[2].parse::<f64>()) {
                if min.is_finite() && sec.is_finite() {
                    line_times.push((min * 60.0 + sec + time_offset).max(0.0));
                }
            }
            rest = &rest[m0.end()..];
        }
        if line_times.is_empty() {
            continue;
        }

        let line_content = rest.trim();
        let first_raw_time = (line_times[0] - time_offset).max(0.0);
        let elrc_data = parse_elrc_line(line_content, first_raw_time);
        let clean_text = elrc_data
            .as_ref()
            .map(|(t, _)| t.clone())
            .unwrap_or_else(|| html_tag_regex().replace_all(line_content, "").trim().to_string());
        let bg = is_bg_vocal(&clean_text);

        let first_line_time = line_times[0];
        for &line_time in &line_times {
            let shift = line_time - first_line_time;
            if let Some((_, ref base_words)) = elrc_data {
                if !base_words.is_empty() {
                    let adjusted: Vec<LyricWord> = base_words
                        .iter()
                        .map(|w| LyricWord {
                            id: next_uid(),
                            text: w.text.clone(),
                            start_time: (w.start_time + time_offset + shift).max(0.0),
                            end_time: (w.end_time + time_offset + shift).max(0.0),
                            index: w.index,
                        })
                        .collect();
                    let line_end = adjusted
                        .last()
                        .map(|w| w.end_time)
                        .unwrap_or(line_time + 3.0);
                    result.push(LyricLine {
                        id: next_uid(),
                        time: line_time,
                        end_time: line_end.max(line_time),
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

// MARK: - Fuzzy Track Matching (Preserves Thai Vowels/Tones & Japanese Dakuten!)

fn is_latin_combining_diacritic(c: char) -> bool {
    matches!(c, '\u{0300}'..='\u{036F}')
}

pub fn simplify_for_match(s: &str) -> String {
    // Strip ONLY Latin combining accents (e.g. é -> e) while keeping Thai vowels/tones & Japanese dakuten intact!
    let stripped: String = s
        .nfd()
        .filter(|c| !is_latin_combining_diacritic(*c))
        .nfc()
        .collect();
    let replaced = stripped
        .to_lowercase()
        .replace(['-', '(', ')', '.', '[', ']', '_', '•', '|'], " ")
        .replace(['\'', '"', '’', '‘'], "");
    replaced.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn clean_streaming_title(track: &str) -> String {
    let mut clean = track.trim().to_string();
    for marker in [
        " (Official Music Video)",
        " (Official Video)",
        " (Official Audio)",
        " (Official Lyric Video)",
        " [Official Video]",
        " [Official Audio]",
        " [Lyrics]",
        " (Lyrics)",
        " - Topic",
    ] {
        if let Some(pos) = clean.to_lowercase().find(&marker.to_lowercase()) {
            if pos > 0 && clean.is_char_boundary(pos) {
                clean.truncate(pos);
            }
        }
    }
    if let Some(idx) = clean.find(" - ") {
        if idx > 0 {
            clean.truncate(idx);
        }
    }
    if let Some(idx) = clean.find(" (") {
        if idx > 0 {
            clean.truncate(idx);
        }
    }
    let trimmed = clean.trim();
    if trimmed.is_empty() {
        track.trim().to_string()
    } else {
        trimmed.to_string()
    }
}

fn clean_streaming_artist(artist: &str) -> String {
    let trimmed = artist.trim();
    if let Some(stripped) = trimmed.strip_suffix(" - Topic") {
        return stripped.trim().to_string();
    }
    if let Some(stripped) = trimmed.strip_suffix("VEVO") {
        if !stripped.trim().is_empty() {
            return stripped.trim().to_string();
        }
    }
    trimmed.to_string()
}

fn match_score(
    track_name: Option<&str>,
    artist_name: Option<&str>,
    expected_track: &str,
    expected_artist: &str,
) -> u8 {
    let Some(t) = track_name else { return 0 };
    let st = simplify_for_match(t);
    let s_exp_t = simplify_for_match(expected_track);
    if st.is_empty() || s_exp_t.is_empty() {
        return 0;
    }

    let track_exact = st == s_exp_t;
    let track_sub = !track_exact
        && (st.contains(&s_exp_t) || s_exp_t.contains(&st))
        && st.chars().count().min(s_exp_t.chars().count()) >= 2;
    if !track_exact && !track_sub {
        return 0;
    }

    let s_exp_a = simplify_for_match(expected_artist);
    if s_exp_a.is_empty() {
        return if track_exact { 2 } else { 1 };
    }
    let Some(a) = artist_name else { return 0 };
    let sa = simplify_for_match(a);
    if sa.is_empty() {
        return 0;
    }

    let artist_exact = sa == s_exp_a;
    let artist_sub = !artist_exact
        && (sa.contains(&s_exp_a) || s_exp_a.contains(&sa))
        && sa.chars().count().min(s_exp_a.chars().count()) >= 2;
    if !artist_exact && !artist_sub {
        return 0;
    }

    match (track_exact, artist_exact) {
        (true, true) => 4,
        (true, false) | (false, true) => 3,
        (false, false) => 2,
    }
}

pub fn is_matching_track(
    track_name: Option<&str>,
    artist_name: Option<&str>,
    expected_track: &str,
    expected_artist: &str,
) -> bool {
    match_score(track_name, artist_name, expected_track, expected_artist) > 0
}

// MARK: - Zero-Copy Arc LRU Cache & Bounded Concurrent Multi-Source Fetcher

struct LruLyricsCache {
    cap: usize,
    entries: VecDeque<(String, Arc<Vec<LyricLine>>)>,
}

impl LruLyricsCache {
    fn new(cap: usize) -> Self {
        Self {
            cap,
            entries: VecDeque::with_capacity(cap),
        }
    }

    fn get(&mut self, key: &str) -> Option<Arc<Vec<LyricLine>>> {
        if let Some(pos) = self.entries.iter().position(|(k, _)| k == key) {
            if let Some(item) = self.entries.remove(pos) {
                let val = item.1.clone();
                self.entries.push_front(item);
                return Some(val);
            }
        }
        None
    }

    fn insert(&mut self, key: String, val: Arc<Vec<LyricLine>>) {
        if let Some(pos) = self.entries.iter().position(|(k, _)| k == &key) {
            self.entries.remove(pos);
        }
        if self.entries.len() >= self.cap {
            self.entries.pop_back();
        }
        self.entries.push_front((key, val));
    }
}

#[derive(Debug, Clone)]
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
    let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
    let resp = crate::shared_https_agent()
        .get(url)
        .timeout(Duration::from_secs(12))
        .set("User-Agent", ua)
        .call()
        .ok()?;
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
    let mut scored: Vec<(u8, LrcResult)> = results
        .into_iter()
        .filter_map(|r| {
            let sc = match_score(
                r.track_name.as_deref(),
                r.artist_name.as_deref(),
                expected_track,
                expected_artist,
            );
            if sc > 0 {
                Some((sc, r))
            } else {
                None
            }
        })
        .collect();
    scored.sort_by(|a, b| b.0.cmp(&a.0));

    if let Some((_, best_synced)) = scored
        .iter()
        .find(|(_, r)| r.synced_lyrics.as_deref().is_some_and(|s| !s.is_empty()))
    {
        if let Some(synced) = best_synced.synced_lyrics.as_deref() {
            return parse_lrc(synced);
        }
    }
    if let Some((_, best_plain)) = scored
        .iter()
        .find(|(_, r)| r.plain_lyrics.as_deref().is_some_and(|s| !s.is_empty()))
    {
        if let Some(plain) = best_plain.plain_lyrics.as_deref() {
            return parse_plain(plain);
        }
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
    if artist.is_empty() {
        return Vec::new();
    }
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

struct LoadingGuard {
    engine: Arc<LyricsEngine>,
    my_id: u64,
}

impl Drop for LoadingGuard {
    fn drop(&mut self) {
        self.engine.active_fetches.fetch_sub(1, Ordering::AcqRel);
        if self.engine.request_id.load(Ordering::Acquire) == self.my_id {
            self.engine.is_loading.store(false, Ordering::Release);
        }
    }
}

pub struct LyricsEngine {
    pub current_lines: Mutex<Arc<Vec<LyricLine>>>,
    pub is_loading: AtomicBool,
    request_id: AtomicU64,
    active_fetches: AtomicUsize,
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
            active_fetches: AtomicUsize::new(0),
            last_query: Mutex::new(String::new()),
            cache: Mutex::new(LruLyricsCache::new(100)),
            endpoints: Mutex::new(LyricsEndpoints::default()),
        }
    }

    pub fn clear(&self) {
        self.request_id.fetch_add(1, Ordering::AcqRel);
        self.is_loading.store(false, Ordering::Release);
        self.last_query
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        *self.current_lines.lock().unwrap_or_else(|e| e.into_inner()) = Arc::new(Vec::new());
    }

    pub fn set_endpoints(&self, lrclib_search: &str, lrclib_get: &str, lyrics_ovh: &str) {
        let mut ep = self.endpoints.lock().unwrap_or_else(|e| e.into_inner());
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

    pub fn snapshot(&self) -> Arc<Vec<LyricLine>> {
        self.current_lines
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Returns true on synchronous cache hit (caller can read lines right away).
    pub fn fetch_lyrics(
        self: &Arc<Self>,
        track_name: &str,
        artist_name: &str,
        album_name: &str,
        ctx: usize,
        callback: Option<LyricsReadyCallback>,
    ) -> bool {
        if track_name.trim().is_empty() {
            return false;
        }
        let cleaned_artist = clean_streaming_artist(artist_name);
        let query_key = format!(
            "{}\0{}\0{}",
            track_name.trim().to_lowercase(),
            cleaned_artist.to_lowercase(),
            album_name.trim().to_lowercase()
        );
        {
            let mut last_q = self.last_query.lock().unwrap_or_else(|e| e.into_inner());
            if *last_q == query_key {
                return false;
            }
            *last_q = query_key.clone();
        }

        let my_id = self.request_id.fetch_add(1, Ordering::AcqRel) + 1;

        {
            let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(hit) = cache.get(&query_key) {
                *self.current_lines.lock().unwrap_or_else(|e| e.into_inner()) = hit;
                self.is_loading.store(false, Ordering::Release);
                return true;
            }
        }

        *self.current_lines.lock().unwrap_or_else(|e| e.into_inner()) = Arc::new(Vec::new());
        self.is_loading.store(true, Ordering::Release);

        // Cap concurrent fetch coordinators to prevent unbounded thread bombs during rapid skipping
        if self.active_fetches.fetch_add(1, Ordering::AcqRel) >= 6 {
            self.active_fetches.fetch_sub(1, Ordering::AcqRel);
            self.is_loading.store(false, Ordering::Release);
            self.last_query
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clear();
            if let Some(cb) = callback {
                cb(ctx, my_id);
            }
            return false;
        }

        let clean_track = clean_streaming_title(track_name);
        let orig_track = track_name.trim().to_string();
        let artist = cleaned_artist;
        let album = album_name.trim().to_string();
        let ep = self
            .endpoints
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let engine = self.clone();

        let spawn_res = thread::Builder::new().name("lyrics-fetch".into()).spawn(move || {
            let _guard = LoadingGuard {
                engine: engine.clone(),
                my_id,
            };

            let dup_titles = clean_track.eq_ignore_ascii_case(&orig_track);

            // Phase 1: Race deduplicated LRCLib queries
            let (tx, rx) = std::sync::mpsc::channel::<(usize, Vec<LyricLine>)>();
            let mut expected_p1 = 0usize;

            if !artist.is_empty() {
                expected_p1 += 1;
                let tx0 = tx.clone();
                let ep_get = ep.lrclib_get.clone();
                let ct = clean_track.clone();
                let ar = artist.clone();
                let al = album.clone();
                if thread::Builder::new().spawn(move || {
                    let _ = tx0.send((0, lrclib_get(&ep_get, &ct, &ar, &al)));
                })
                .is_err()
                {
                    expected_p1 -= 1;
                }
            }

            {
                expected_p1 += 1;
                let tx1 = tx.clone();
                let ep_s = ep.lrclib_search.clone();
                let ct = clean_track.clone();
                let ar = artist.clone();
                if thread::Builder::new().spawn(move || {
                    let q = if ar.is_empty() {
                        ct.clone()
                    } else {
                        format!("{ct} {ar}")
                    };
                    let _ = tx1.send((1, lrclib_search(&ep_s, &q, &ct, &ar)));
                })
                .is_err()
                {
                    expected_p1 -= 1;
                }
            }

            if !dup_titles {
                expected_p1 += 1;
                let tx2 = tx.clone();
                let ep_s = ep.lrclib_search.clone();
                let ot = orig_track.clone();
                let ar = artist.clone();
                if thread::Builder::new().spawn(move || {
                    let q = if ar.is_empty() {
                        ot.clone()
                    } else {
                        format!("{ot} {ar}")
                    };
                    let _ = tx2.send((2, lrclib_search(&ep_s, &q, &ot, &ar)));
                })
                .is_err()
                {
                    expected_p1 -= 1;
                }
            }
            drop(tx);

            let mut winner: Option<Vec<LyricLine>> = None;
            let mut collected: [Option<Vec<LyricLine>>; 3] = [None, None, None];
            let mut received = 0usize;
            while received < expected_p1 {
                if engine.request_id.load(Ordering::Acquire) != my_id {
                    return;
                }
                match rx.recv_timeout(Duration::from_millis(120)) {
                    Ok((idx, res)) => {
                        received += 1;
                        if !res.is_empty() {
                            let is_synced = res
                                .last()
                                .is_some_and(|l| l.time > 0.0 || l.end_time > 0.0);
                            if is_synced {
                                winner = Some(res);
                                break;
                            }
                            if idx < 3 {
                                collected[idx] = Some(res);
                            }
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
            if winner.is_none() {
                winner = collected.into_iter().flatten().find(|v| !v.is_empty());
            }

            if engine.request_id.load(Ordering::Acquire) != my_id {
                return;
            }

            if let Some(lines) = winner {
                let arc_lines = Arc::new(lines);
                engine
                    .cache
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(query_key, arc_lines.clone());
                *engine
                    .current_lines
                    .lock()
                    .unwrap_or_else(|e| e.into_inner()) = arc_lines;
                engine.is_loading.store(false, Ordering::Release);
                if let Some(cb) = callback {
                    cb(ctx, my_id);
                }
                return;
            }

            // Phase 2: Deduplicated OVH fallback
            let mut final_ovh = Vec::new();
            if !artist.is_empty() {
                let (otx, orx) = std::sync::mpsc::channel::<Vec<LyricLine>>();
                let mut expected_p2 = 0usize;
                {
                    expected_p2 += 1;
                    let tx0 = otx.clone();
                    let ep_o = ep.lyrics_ovh.clone();
                    let ct = clean_track;
                    let ar = artist.clone();
                    if thread::Builder::new().spawn(move || {
                        let _ = tx0.send(ovh_fetch(&ep_o, &ct, &ar));
                    })
                    .is_err()
                    {
                        expected_p2 -= 1;
                    }
                }
                if !dup_titles {
                    expected_p2 += 1;
                    let tx1 = otx.clone();
                    let ep_o = ep.lyrics_ovh;
                    let ot = orig_track;
                    let ar = artist;
                    if thread::Builder::new().spawn(move || {
                        let _ = tx1.send(ovh_fetch(&ep_o, &ot, &ar));
                    })
                    .is_err()
                    {
                        expected_p2 -= 1;
                    }
                }
                drop(otx);

                let mut got2 = 0usize;
                while got2 < expected_p2 {
                    if engine.request_id.load(Ordering::Acquire) != my_id {
                        return;
                    }
                    match orx.recv_timeout(Duration::from_millis(120)) {
                        Ok(res) => {
                            got2 += 1;
                            if !res.is_empty() {
                                final_ovh = res;
                                break;
                            }
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                }
            }

            if engine.request_id.load(Ordering::Acquire) != my_id {
                return;
            }

            if !final_ovh.is_empty() {
                let arc_lines = Arc::new(final_ovh);
                engine
                    .cache
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(query_key, arc_lines.clone());
                *engine
                    .current_lines
                    .lock()
                    .unwrap_or_else(|e| e.into_inner()) = arc_lines;
            } else {
                // Do NOT permanently cache empty/failed network results; allow future retry
                let mut lq = engine.last_query.lock().unwrap_or_else(|e| e.into_inner());
                if *lq == query_key {
                    lq.clear();
                }
                *engine
                    .current_lines
                    .lock()
                    .unwrap_or_else(|e| e.into_inner()) = Arc::new(Vec::new());
            }
            engine.is_loading.store(false, Ordering::Release);
            if let Some(cb) = callback {
                cb(ctx, my_id);
            }
        });

        if spawn_res.is_err() {
            self.active_fetches.fetch_sub(1, Ordering::AcqRel);
            self.is_loading.store(false, Ordering::Release);
            self.last_query
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clear();
            if let Some(cb) = callback {
                cb(ctx, my_id);
            }
        }

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
    fn test_parse_elrc_syllable_continuation_and_brackets() {
        let lrc = "[00:10.00]<00:10.00>beau<00:10.25>ti<00:10.50>ful <00:10.80>day\n[00:12.00]fast [00:12.20]words\n";
        let lines = parse_lrc(lrc);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[0].text, "beautiful");
        assert_eq!(lines[0].words[1].text, "day");
        assert!(lines[0].words[0].end_time >= 10.7);
        assert_eq!(lines[1].text, "fast words");
        assert_eq!(lines[1].words.len(), 2);
        assert!((lines[1].words[0].start_time - 12.0).abs() < 0.01);
        assert!((lines[1].words[1].start_time - 12.2).abs() < 0.01);
    }

    #[test]
    fn test_parse_ttml_reordered_attrs_and_entities() {
        let ttml = r#"<tt><body><p xml:id="p1" ttm:agent="v1" begin="1000ms" end="4.5s"><span ttm:role="x" begin="1000ms" end="2.0s">Rock &amp;</span><span begin="2.0s" end="4.5s">Roll&#39;s</span></p></body></tt>"#;
        let lines = parse_ttml(ttml);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text, "Rock & Roll's");
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[0].index, 0);
        assert_eq!(lines[0].words[1].index, 1);
        assert!((lines[0].time - 1.0).abs() < 0.01);
        assert!((lines[0].end_time - 4.5).abs() < 0.01);
    }

    #[test]
    fn test_plain_ovh_strip_and_thai_decode() {
        let plain = "Paroles de la chanson Test par Artist\n\nLine 1\nLine 2\n";
        let lines = parse_plain(plain);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text, "Line 1");

        let decoded = decode_bytes(&[0xA1]);
        assert_eq!(decoded, "ก");
    }

    #[test]
    fn test_fuzzy_match_diacritics_and_thai_preservation() {
        assert!(is_matching_track(
            Some("Déjà Vu (Deluxe)"),
            Some("Beyoncé"),
            "Deja Vu",
            "Beyonce"
        ));
        // Multi-space collapse on punctuation
        assert_eq!(simplify_for_match("Mr. Brightside"), "mr brightside");
        // Thai vowels and tone marks MUST be preserved (never collapsed to unrelated words!)
        assert_ne!(simplify_for_match("ปา"), simplify_for_match("ป่า"));
        assert_ne!(simplify_for_match("ใกล้"), simplify_for_match("ไกล"));
    }

    #[test]
    fn test_fast_rap_word_timings_never_invert() {
        let lrc = "[00:01.00]one two three four five six seven eight nine ten eleven twelve\n[00:01.60]next\n";
        let lines = parse_lrc(lrc);
        for w in &lines[0].words {
            assert!(w.start_time <= w.end_time);
            assert!(w.end_time <= lines[0].end_time + 1e-6);
        }
    }
}
