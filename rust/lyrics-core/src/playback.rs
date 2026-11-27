use crate::lyrics::LyricLine;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum MusicSource {
    Auto = 0,
    Spotify = 1,
    AppleMusic = 2,
}

impl MusicSource {
    pub fn from_i32(v: i32) -> Self {
        match v {
            1 => Self::Spotify,
            2 => Self::AppleMusic,
            _ => Self::Auto,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlaybackTrack {
    pub id: String,
    pub name: String,
    pub artist: String,
    pub album: String,
    pub artwork_url: String,
    pub duration: f64,
    pub source: MusicSource,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct PlaybackDelta {
    pub track_changed: bool,
    pub artwork_url_changed: bool,
    pub play_state_changed: bool,
    pub source_changed: bool,
}

#[derive(Debug, Clone)]
pub struct MenuBarLyricResolved {
    pub text: String,
    pub line_id: u64,
    pub progress: f64,
    pub is_intro: bool,
    pub is_unsynced: bool,
    pub is_interlude: bool,
    pub peeked_ahead: bool,
    pub active_word_index: i32,
    pub active_word_progress: f64,
    pub active_word_after_end: bool,
    pub active_word_before_start: bool,
    pub line_changed: bool,
    pub transition_progress: f64,
    pub animated_orb_alpha: f64,
    pub art_scale: f64,
    pub art_opacity: f64,
    pub needs_active_frames: bool,
    pub is_sparkling_candidate: bool,
    pub sparkle_cycle_time: f64,
}

pub struct PlaybackEngine {
    pub current_track: Option<PlaybackTrack>,
    pub is_playing: bool,
    pub playback_position: f64,
    pub last_update_mono: f64,
    pub last_monotonic_time: f64,
    pub monotonic_track_id: String,
    pub active_source: MusicSource,
    pub consecutive_stopped_polls: i32,

    // Menu bar animation physics state
    pub last_rendered_text: String,
    pub transition_progress: f64,
    pub animated_orb_alpha: f64,
    pub art_scale: f64,
    pub art_opacity: f64,
    pub track_changed_unix: f64,
    pub last_sparkle_track_id: String,
}

impl PlaybackEngine {
    pub fn new() -> Self {
        Self {
            current_track: None,
            is_playing: false,
            playback_position: 0.0,
            last_update_mono: 0.0,
            last_monotonic_time: 0.0,
            monotonic_track_id: String::new(),
            active_source: MusicSource::Spotify,
            consecutive_stopped_polls: 0,
            last_rendered_text: String::new(),
            transition_progress: 1.0,
            animated_orb_alpha: 0.0,
            art_scale: 1.0,
            art_opacity: 1.0,
            track_changed_unix: 0.0,
            last_sparkle_track_id: String::new(),
        }
    }

    pub fn update_playback_state(
        &mut self,
        track: PlaybackTrack,
        position: f64,
        is_playing: bool,
        source: MusicSource,
        now_mono: f64,
        now_unix: f64,
    ) -> PlaybackDelta {
        self.consecutive_stopped_polls = 0;

        let track_changed = match &self.current_track {
            None => !track.name.is_empty(),
            Some(cur) => {
                cur.name.to_lowercase() != track.name.to_lowercase()
                    || cur.artist.to_lowercase() != track.artist.to_lowercase()
            }
        };
        let artwork_url_changed = self
            .current_track
            .as_ref()
            .map(|c| c.artwork_url != track.artwork_url)
            .unwrap_or(false);
        let play_state_changed = self.is_playing != is_playing;
        let source_changed = self.active_source != source;

        let expected = if self.is_playing {
            self.playback_position + (now_mono - self.last_update_mono).max(0.0)
        } else {
            self.playback_position
        };
        let delta = position - expected;

        if track_changed || play_state_changed || delta < -0.25 || delta > 1.2 {
            self.playback_position = position;
            self.last_update_mono = now_mono;
            self.last_monotonic_time = position;
            self.monotonic_track_id = track.id.clone();
        } else {
            self.playback_position = position;
            self.last_update_mono = now_mono;
            if delta.abs() > 0.35 {
                self.last_monotonic_time = position;
            }
        }

        if source_changed {
            self.active_source = source;
        }
        if play_state_changed {
            self.is_playing = is_playing;
            if !is_playing {
                self.transition_progress = 1.0;
            }
        }

        if track_changed {
            self.track_changed_unix = now_unix;
            self.last_sparkle_track_id = track.id.clone();
        }

        let mut merged = track;
        if !track_changed {
            if merged.artwork_url.is_empty() {
                if let Some(cur) = &self.current_track {
                    merged.artwork_url = cur.artwork_url.clone();
                }
            }
        }
        self.current_track = Some(merged);

        PlaybackDelta {
            track_changed,
            artwork_url_changed,
            play_state_changed,
            source_changed,
        }
    }

    pub fn mark_stopped(&mut self, source: MusicSource, threshold: i32, is_not_running: bool) -> bool {
        self.consecutive_stopped_polls += 1;
        if self.consecutive_stopped_polls > threshold
            && (self.active_source == source || is_not_running)
        {
            self.current_track = None;
            self.is_playing = false;
            self.playback_position = 0.0;
            self.last_monotonic_time = 0.0;
            self.last_rendered_text.clear();
            self.transition_progress = 1.0;
            return true;
        }
        false
    }

    pub fn current_time(&mut self, now_mono: f64) -> f64 {
        let Some(ref track) = self.current_track else {
            self.last_monotonic_time = 0.0;
            return 0.0;
        };
        let raw = if self.is_playing {
            self.playback_position + (now_mono - self.last_update_mono).max(0.0)
        } else {
            self.playback_position
        };
        let clamped = raw.max(0.0);

        if self.monotonic_track_id != track.id
            || !self.is_playing
            || clamped < (self.last_monotonic_time - 0.25)
            || clamped > (self.last_monotonic_time + 1.2)
        {
            self.monotonic_track_id = track.id.clone();
            self.last_monotonic_time = clamped;
            return clamped;
        }
        if clamped > self.last_monotonic_time {
            self.last_monotonic_time = clamped;
        }
        self.last_monotonic_time
    }

    pub fn seek_local(&mut self, target_time: f64, now_mono: f64) {
        let t = target_time.max(0.0);
        self.playback_position = t;
        self.last_update_mono = now_mono;
        self.last_monotonic_time = t;
    }

    pub fn resolve_hud_active_index(lines: &[LyricLine], time: f64, duration: f64) -> (i32, bool) {
        if lines.is_empty() {
            return (-1, false);
        }
        let is_unsynced = lines.len() > 1 && lines.last().is_some_and(|l| l.time == 0.0);
        if is_unsynced {
            let dur = if duration > 0.0 { duration } else { 100.0 };
            let progress = (time / dur).clamp(0.0, 1.0);
            let idx = ((progress * (lines.len() as f64)) as usize).min(lines.len() - 1);
            return (idx as i32, true);
        }
        if let Some(first) = lines.first() {
            if time < first.time {
                return (-1, false);
            }
        }
        let mut active = 0i32;
        for (i, line) in lines.iter().enumerate() {
            if line.time <= time {
                active = i as i32;
            } else {
                break;
            }
        }
        (active, false)
    }

    pub fn step_menubar_frame(
        &mut self,
        lines: &[LyricLine],
        dt: f64,
        now_mono: f64,
        now_unix: f64,
        is_loading_lyrics: bool,
        is_ultra_light: bool,
    ) -> Option<MenuBarLyricResolved> {
        let time = self.current_time(now_mono);
        let track = self.current_track.as_ref()?.clone();

        if self.last_sparkle_track_id != track.id {
            self.last_sparkle_track_id = track.id.clone();
            self.track_changed_unix = now_unix;
        }
        let sparkle_time = (now_unix - self.track_changed_unix).max(0.0);

        let mut current_line_text: String;
        let mut is_unsynced = false;
        let mut current_index: usize = 0;
        let mut peeked_ahead = false;
        let mut is_intro = false;

        if !lines.is_empty() {
            is_unsynced = lines.len() > 1 && lines.last().is_some_and(|l| l.time == 0.0);
            if is_unsynced {
                let dur = if track.duration > 0.0 {
                    track.duration
                } else {
                    100.0
                };
                let p = (time / dur).clamp(0.0, 1.0);
                current_index = ((p * (lines.len() as f64)) as usize).min(lines.len() - 1);
                current_line_text = lines[current_index].text.clone();
            } else if lines[0].time > 0.0 && time < lines[0].time {
                is_intro = true;
                if sparkle_time < 5.5 {
                    current_line_text = track.name.clone();
                } else {
                    current_line_text = format!("♪ {} - {}", track.name, track.artist);
                }
            } else {
                for (idx, line) in lines.iter().enumerate() {
                    if line.time <= time {
                        current_index = idx;
                    } else {
                        break;
                    }
                }
                let active_line = &lines[current_index];
                current_line_text = active_line.text.clone();
                if current_line_text.trim().is_empty() {
                    if current_index + 1 < lines.len() {
                        let next_t = lines[current_index + 1].text.trim();
                        if !next_t.is_empty() {
                            current_line_text = next_t.to_string();
                            peeked_ahead = true;
                        } else {
                            current_line_text = "♪".to_string();
                        }
                    } else {
                        current_line_text = "♪".to_string();
                    }
                }
            }
        } else if is_loading_lyrics || sparkle_time < 5.5 {
            current_line_text = track.name.clone();
        } else {
            current_line_text = format!("{} - {} • {}", track.name, track.artist, track.album);
        }

        if current_line_text.is_empty() {
            current_line_text = "♪".to_string();
        }
        if current_line_text.chars().count() > 75 {
            let truncated: String = current_line_text.chars().take(72).collect();
            current_line_text = format!("{truncated}...");
        }

        let line_id = if lines.is_empty() || is_intro {
            0
        } else {
            lines[current_index].id
        };

        let mut progress = 0.0_f64;
        let mut active_word_index: i32 = -1;
        let mut active_word_progress = 0.0_f64;
        let mut active_word_before_start = false;
        let mut active_word_after_end = false;

        if !is_intro && !lines.is_empty() && current_index < lines.len() {
            let active_line = &lines[current_index];
            if peeked_ahead {
                progress = 0.0;
            } else if is_unsynced {
                progress = 1.0;
                active_word_after_end = true;
            } else if !active_line.words.is_empty() && active_line.end_time > active_line.time {
                let vocal_start = active_line
                    .words
                    .first()
                    .map(|w| w.start_time)
                    .unwrap_or(active_line.time);
                let vocal_end = active_line
                    .words
                    .last()
                    .map(|w| w.end_time)
                    .unwrap_or(active_line.end_time);
                let vocal_dur = (vocal_end - vocal_start).max(0.01);

                if time < vocal_start {
                    progress = 0.0;
                    active_word_before_start = true;
                } else if time >= vocal_end {
                    progress = 1.0;
                    active_word_after_end = true;
                } else {
                    progress = ((time - vocal_start) / vocal_dur).clamp(0.0, 1.0);
                    for (wi, w) in active_line.words.iter().enumerate() {
                        if time >= w.start_time && time < w.end_time {
                            active_word_index = wi as i32;
                            let w_dur = (w.end_time - w.start_time).max(0.01);
                            active_word_progress = ((time - w.start_time) / w_dur).clamp(0.0, 1.0);
                            break;
                        } else if time < w.start_time {
                            active_word_index = wi as i32;
                            active_word_progress = 0.0;
                            break;
                        }
                    }
                }
            } else if current_index + 1 < lines.len() {
                let cur_start = lines[current_index].time;
                let next_start = lines[current_index + 1].time;
                let active_dur = (next_start - cur_start).max(0.1).min(8.0);
                progress = ((time - cur_start) / active_dur).clamp(0.0, 1.0);
            } else {
                progress = 1.0;
            }
        }

        let line_changed = current_line_text != self.last_rendered_text;
        if line_changed {
            self.last_rendered_text = current_line_text.clone();
            self.transition_progress = 0.0;
        }
        if self.transition_progress < 1.0 {
            self.transition_progress = (self.transition_progress + dt / 0.42).min(1.0);
        }

        let target_orb = if progress > 0.0 && progress < 1.0 {
            1.0
        } else {
            0.0
        };
        let alpha_smooth = 1.0 - (-15.0 * dt).exp();
        self.animated_orb_alpha += (target_orb - self.animated_orb_alpha) * alpha_smooth;

        let target_art_scale = if self.is_playing { 1.0 } else { 0.82 };
        let target_art_opacity = if self.is_playing { 1.0 } else { 0.74 };
        let art_lerp = 1.0 - (-10.0 * dt).exp();
        self.art_scale += (target_art_scale - self.art_scale) * art_lerp;
        self.art_opacity += (target_art_opacity - self.art_opacity) * art_lerp;
        if (target_art_scale - self.art_scale).abs() < 0.004 {
            self.art_scale = target_art_scale;
            self.art_opacity = target_art_opacity;
        }

        let is_paused_settling = !self.is_playing
            && ((self.art_scale - 0.82).abs() > 0.005 || self.transition_progress < 1.0);
        let needs_active_frames = self.is_playing || is_paused_settling;

        let total_sparkle_dur = 5.5_f64;
        let is_sparkling_candidate = !is_ultra_light
            && (is_loading_lyrics || (sparkle_time < total_sparkle_dur && current_line_text == track.name));
        let sparkle_cycle_time = if is_loading_lyrics {
            sparkle_time % total_sparkle_dur
        } else {
            sparkle_time
        };
        let is_interlude = current_line_text.contains('✦');

        Some(MenuBarLyricResolved {
            text: current_line_text,
            line_id,
            progress,
            is_intro,
            is_unsynced,
            is_interlude,
            peeked_ahead,
            active_word_index,
            active_word_progress,
            active_word_after_end,
            active_word_before_start,
            line_changed,
            transition_progress: self.transition_progress,
            animated_orb_alpha: self.animated_orb_alpha,
            art_scale: self.art_scale,
            art_opacity: self.art_opacity,
            needs_active_frames,
            is_sparkling_candidate,
            sparkle_cycle_time,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lyrics::parse_lrc;

    #[test]
    fn test_monotonic_clock_and_seek_resync() {
        let mut pb = PlaybackEngine::new();
        let tr = PlaybackTrack {
            id: "sp:1".into(),
            name: "Song".into(),
            artist: "Artist".into(),
            album: "Album".into(),
            artwork_url: "".into(),
            duration: 180.0,
            source: MusicSource::Spotify,
        };
        pb.update_playback_state(tr.clone(), 10.0, true, MusicSource::Spotify, 100.0, 1000.0);
        let t1 = pb.current_time(101.0);
        assert!((t1 - 11.0).abs() < 0.01);

        // Small backward jitter <= 0.25s clamped forward
        pb.update_playback_state(tr.clone(), 10.9, true, MusicSource::Spotify, 101.0, 1001.0);
        assert!(pb.current_time(101.0) >= 11.0);

        // Real backward seek > 0.25s resyncs cleanly
        pb.update_playback_state(tr, 4.0, true, MusicSource::Spotify, 102.0, 1002.0);
        assert!((pb.current_time(102.0) - 4.0).abs() < 0.01);
    }

    #[test]
    fn test_pause_settle_to_082() {
        let mut pb = PlaybackEngine::new();
        let tr = PlaybackTrack {
            id: "sp:1".into(),
            name: "Song".into(),
            artist: "Artist".into(),
            album: "Album".into(),
            artwork_url: "".into(),
            duration: 180.0,
            source: MusicSource::Spotify,
        };
        let lines = parse_lrc("[00:05.00]Hello\n[00:10.00]World\n");
        pb.update_playback_state(tr, 6.0, false, MusicSource::Spotify, 10.0, 100.0);

        let mut last_res = None;
        for step in 0..80 {
            last_res = pb.step_menubar_frame(&lines, 0.016, 10.0 + (step as f64) * 0.016, 100.0, false, false);
        }
        let r = last_res.unwrap();
        assert!((r.art_scale - 0.82).abs() <= 0.005);
        assert!(!r.needs_active_frames);
    }
}
