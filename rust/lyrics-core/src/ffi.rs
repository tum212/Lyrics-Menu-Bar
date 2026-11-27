use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::color::{
    download_url_bytes, extract_waveform_theme_rgba, fetch_itunes_artwork_bytes,
    sanitize_artwork_url, WaveformTheme,
};
use crate::dsp::{AudioDspEngine, MAX_BANDS};
use crate::haptics::{CHHapticFallbackFn, HapticEngine};
use crate::lyrics::{LyricsEngine, LyricsReadyCallback};
use crate::playback::{MusicSource, PlaybackDelta, PlaybackEngine, PlaybackTrack};
use crate::updater::{check_updates, download_dmg_streaming, is_version_greater};

pub struct LyricsAudioHandle {
    pub dsp: AudioDspEngine,
}

pub struct LyricsHapticsHandle {
    pub engine: Arc<HapticEngine>,
}

pub struct LyricsCoreHandle {
    pub lyrics: Arc<LyricsEngine>,
    pub playback: Mutex<PlaybackEngine>,
    pub download_cancel: Arc<AtomicBool>,
}

#[repr(C)]
pub struct CFfiRgbaColor {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[repr(C)]
pub struct CFfiWaveformTheme {
    pub top: CFfiRgbaColor,
    pub bottom: CFfiRgbaColor,
    pub glow: CFfiRgbaColor,
    pub accent: CFfiRgbaColor,
}

#[repr(C)]
pub struct CFfiPlaybackDelta {
    pub track_changed: bool,
    pub artwork_url_changed: bool,
    pub play_state_changed: bool,
    pub source_changed: bool,
}

#[repr(C)]
pub struct CFfiMenuBarFrame {
    pub has_track: bool,
    pub text_ptr: *mut c_char,
    pub line_id: u64,
    pub progress: f64,
    pub is_intro: bool,
    pub is_unsynced: bool,
    pub is_interlude: bool,
    pub peeked_ahead: bool,
    pub active_word_index: i32,
    pub active_word_progress: f64,
    pub active_word_before_start: bool,
    pub active_word_after_end: bool,
    pub line_changed: bool,
    pub transition_progress: f64,
    pub animated_orb_alpha: f64,
    pub art_scale: f64,
    pub art_opacity: f64,
    pub needs_active_frames: bool,
    pub is_sparkling_candidate: bool,
    pub sparkle_cycle_time: f64,
}

#[repr(C)]
pub struct CFfiByteBuffer {
    pub data: *mut u8,
    pub len: usize,
}

unsafe fn cstr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

fn to_cstring_raw(s: &str) -> *mut c_char {
    let cleaned = s.replace('\0', "");
    CString::new(cleaned)
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

// MARK: - Memory Management

#[no_mangle]
pub extern "C" fn lyrics_core_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

#[no_mangle]
pub extern "C" fn lyrics_core_free_bytes(buf: CFfiByteBuffer) {
    if !buf.data.is_null() && buf.len > 0 {
        unsafe {
            let _ = Vec::from_raw_parts(buf.data, buf.len, buf.len);
        }
    }
}

// MARK: - Core Lifecycle

#[no_mangle]
pub extern "C" fn lyrics_core_create() -> *mut LyricsCoreHandle {
    catch_unwind(|| {
        Box::into_raw(Box::new(LyricsCoreHandle {
            lyrics: Arc::new(LyricsEngine::new()),
            playback: Mutex::new(PlaybackEngine::new()),
            download_cancel: Arc::new(AtomicBool::new(false)),
        }))
    })
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn lyrics_core_destroy(handle: *mut LyricsCoreHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}

// MARK: - Audio DSP

#[no_mangle]
pub extern "C" fn lyrics_core_audio_create() -> *mut LyricsAudioHandle {
    catch_unwind(|| {
        Box::into_raw(Box::new(LyricsAudioHandle {
            dsp: AudioDspEngine::new(),
        }))
    })
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn lyrics_core_audio_destroy(handle: *mut LyricsAudioHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}

#[no_mangle]
pub extern "C" fn lyrics_core_audio_update_band_count(
    handle: *mut LyricsAudioHandle,
    band_count: i32,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(h) = unsafe { handle.as_ref() } {
            h.dsp.update_band_count(band_count.max(1) as usize);
        }
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_audio_reset(handle: *mut LyricsAudioHandle) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(h) = unsafe { handle.as_ref() } {
            h.dsp.reset();
        }
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_audio_process_pcm(
    handle: *mut LyricsAudioHandle,
    left: *const f32,
    right: *const f32,
    frame_or_float_len: usize,
    channels: usize,
    sample_rate: f32,
    output_host_time: u64,
    haptic_intensity: i32,
    haptics_handle: *const LyricsHapticsHandle,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Some(audio) = (unsafe { handle.as_ref() }) else {
            return;
        };
        if left.is_null() || frame_or_float_len == 0 {
            return;
        }
        let left_slice = unsafe { slice::from_raw_parts(left, frame_or_float_len) };
        let right_slice = if right.is_null() {
            None
        } else {
            Some(unsafe { slice::from_raw_parts(right, frame_or_float_len) })
        };
        let haptics = unsafe { haptics_handle.as_ref() }.map(|hh| hh.engine.as_ref());
        audio.dsp.process_pcm(
            left_slice,
            right_slice,
            channels,
            sample_rate,
            output_host_time,
            haptic_intensity,
            haptics,
        );
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_audio_tick_bars(
    handle: *mut LyricsAudioHandle,
    delta_time: f64,
    now_unix: f64,
    is_playing: bool,
    is_tap_running: bool,
    bar_count: usize,
    out_heights: *mut f32,
    out_capacity: usize,
) -> usize {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(audio) = (unsafe { handle.as_ref() }) else {
            return 0;
        };
        if out_heights.is_null() || out_capacity == 0 {
            return 0;
        }
        let buf = unsafe { slice::from_raw_parts_mut(out_heights, out_capacity.min(MAX_BANDS)) };
        audio.dsp.tick_waveform_bars(
            delta_time,
            now_unix,
            is_playing,
            is_tap_running,
            bar_count,
            buf,
        )
    }))
    .unwrap_or(0)
}

// MARK: - Haptics

#[no_mangle]
pub extern "C" fn lyrics_core_haptics_create() -> *mut LyricsHapticsHandle {
    catch_unwind(|| {
        Box::into_raw(Box::new(LyricsHapticsHandle {
            engine: Arc::new(HapticEngine::new()),
        }))
    })
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn lyrics_core_haptics_destroy(handle: *mut LyricsHapticsHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}

#[no_mangle]
pub extern "C" fn lyrics_core_haptics_has_multitouch(handle: *const LyricsHapticsHandle) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        unsafe { handle.as_ref() }
            .map(|h| h.engine.has_multitouch_actuator())
            .unwrap_or(false)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn lyrics_core_haptics_set_actuator_type(
    handle: *const LyricsHapticsHandle,
    actuator_type: i32,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(h) = unsafe { handle.as_ref() } {
            h.engine.set_actuator_type(actuator_type);
        }
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_haptics_set_latency_offset(
    handle: *const LyricsHapticsHandle,
    offset_secs: f64,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(h) = unsafe { handle.as_ref() } {
            h.engine.set_latency_offset(offset_secs);
        }
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_haptics_set_fallback(
    handle: *const LyricsHapticsHandle,
    callback: Option<CHHapticFallbackFn>,
    ctx: *mut c_void,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(h) = unsafe { handle.as_ref() } {
            h.engine.set_fallback_callback(callback, ctx);
        }
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_haptics_test_type(
    handle: *const LyricsHapticsHandle,
    actuator_type: i32,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(h) = unsafe { handle.as_ref() } {
            h.engine.test_actuator_type(actuator_type);
        }
    }));
}

// MARK: - Lyrics Engine

#[no_mangle]
pub extern "C" fn lyrics_core_lyrics_set_endpoints(
    handle: *mut LyricsCoreHandle,
    lrclib_search: *const c_char,
    lrclib_get: *const c_char,
    lyrics_ovh: *const c_char,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = (unsafe { handle.as_ref() }) else {
            return;
        };
        let s = unsafe { cstr_to_string(lrclib_search) };
        let g = unsafe { cstr_to_string(lrclib_get) };
        let o = unsafe { cstr_to_string(lyrics_ovh) };
        core.lyrics.set_endpoints(&s, &g, &o);
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_lyrics_clear(handle: *mut LyricsCoreHandle) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(core) = unsafe { handle.as_ref() } {
            core.lyrics.clear();
        }
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_lyrics_fetch(
    handle: *mut LyricsCoreHandle,
    track: *const c_char,
    artist: *const c_char,
    album: *const c_char,
    ctx: usize,
    callback: LyricsReadyCallback,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = (unsafe { handle.as_ref() }) else {
            return false;
        };
        let t = unsafe { cstr_to_string(track) };
        let a = unsafe { cstr_to_string(artist) };
        let al = unsafe { cstr_to_string(album) };
        core.lyrics.fetch_lyrics(&t, &a, &al, ctx, callback)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn lyrics_core_lyrics_is_loading(handle: *const LyricsCoreHandle) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        unsafe { handle.as_ref() }
            .map(|c| c.lyrics.is_loading.load(Ordering::Acquire))
            .unwrap_or(false)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn lyrics_core_lyrics_get_json(handle: *const LyricsCoreHandle) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = (unsafe { handle.as_ref() }) else {
            return to_cstring_raw("[]");
        };
        let lines = core.lyrics.snapshot();
        match serde_json::to_string(&*lines) {
            Ok(json) => to_cstring_raw(&json),
            Err(_) => to_cstring_raw("[]"),
        }
    }))
    .unwrap_or(ptr::null_mut())
}

// MARK: - Playback & Menu Bar State Machine

#[no_mangle]
pub extern "C" fn lyrics_core_playback_update(
    handle: *mut LyricsCoreHandle,
    id: *const c_char,
    name: *const c_char,
    artist: *const c_char,
    album: *const c_char,
    artwork_url: *const c_char,
    duration: f64,
    position: f64,
    is_playing: bool,
    source: i32,
    now_mono: f64,
    now_unix: f64,
) -> CFfiPlaybackDelta {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = (unsafe { handle.as_ref() }) else {
            return CFfiPlaybackDelta {
                track_changed: false,
                artwork_url_changed: false,
                play_state_changed: false,
                source_changed: false,
            };
        };
        let track = PlaybackTrack {
            id: unsafe { cstr_to_string(id) },
            name: unsafe { cstr_to_string(name) },
            artist: unsafe { cstr_to_string(artist) },
            album: unsafe { cstr_to_string(album) },
            artwork_url: unsafe { cstr_to_string(artwork_url) },
            duration,
            source: MusicSource::from_i32(source),
        };
        let delta: PlaybackDelta = core
            .playback
            .lock()
            .map(|mut pb| {
                pb.update_playback_state(
                    track,
                    position,
                    is_playing,
                    MusicSource::from_i32(source),
                    now_mono,
                    now_unix,
                )
            })
            .unwrap_or_default();

        CFfiPlaybackDelta {
            track_changed: delta.track_changed,
            artwork_url_changed: delta.artwork_url_changed,
            play_state_changed: delta.play_state_changed,
            source_changed: delta.source_changed,
        }
    }))
    .unwrap_or(CFfiPlaybackDelta {
        track_changed: false,
        artwork_url_changed: false,
        play_state_changed: false,
        source_changed: false,
    })
}

#[no_mangle]
pub extern "C" fn lyrics_core_playback_mark_stopped(
    handle: *mut LyricsCoreHandle,
    source: i32,
    threshold: i32,
    is_not_running: bool,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = (unsafe { handle.as_ref() }) else {
            return false;
        };
        core.playback
            .lock()
            .map(|mut pb| pb.mark_stopped(MusicSource::from_i32(source), threshold, is_not_running))
            .unwrap_or(false)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn lyrics_core_playback_current_time(
    handle: *mut LyricsCoreHandle,
    now_mono: f64,
) -> f64 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = (unsafe { handle.as_ref() }) else {
            return 0.0;
        };
        core.playback
            .lock()
            .map(|mut pb| pb.current_time(now_mono))
            .unwrap_or(0.0)
    }))
    .unwrap_or(0.0)
}

#[no_mangle]
pub extern "C" fn lyrics_core_playback_seek_local(
    handle: *mut LyricsCoreHandle,
    target_time: f64,
    now_mono: f64,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(core) = unsafe { handle.as_ref() } {
            if let Ok(mut pb) = core.playback.lock() {
                pb.seek_local(target_time, now_mono);
            }
        }
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_playback_set_playing_local(
    handle: *mut LyricsCoreHandle,
    is_playing: bool,
    now_mono: f64,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(core) = unsafe { handle.as_ref() } {
            if let Ok(mut pb) = core.playback.lock() {
                let cur = pb.current_time(now_mono);
                pb.playback_position = cur;
                pb.last_update_mono = now_mono;
                pb.is_playing = is_playing;
                if !is_playing {
                    pb.transition_progress = 1.0;
                }
            }
        }
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_playback_hud_active_index(
    handle: *mut LyricsCoreHandle,
    now_mono: f64,
    out_is_unsynced: *mut bool,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = (unsafe { handle.as_ref() }) else {
            return -1;
        };
        let lines = core.lyrics.snapshot();
        let (time, dur) = core
            .playback
            .lock()
            .map(|mut pb| {
                let d = pb.current_track.as_ref().map(|t| t.duration).unwrap_or(100.0);
                let t = pb.current_time(now_mono);
                (t, d)
            })
            .unwrap_or((0.0, 100.0));
        let (idx, unsynced) = PlaybackEngine::resolve_hud_active_index(&lines, time, dur);
        if !out_is_unsynced.is_null() {
            unsafe {
                *out_is_unsynced = unsynced;
            }
        }
        idx
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn lyrics_core_menubar_step(
    handle: *mut LyricsCoreHandle,
    dt: f64,
    now_mono: f64,
    now_unix: f64,
    is_ultra_light: bool,
) -> CFfiMenuBarFrame {
    catch_unwind(AssertUnwindSafe(|| {
        let empty = CFfiMenuBarFrame {
            has_track: false,
            text_ptr: ptr::null_mut(),
            line_id: 0,
            progress: 0.0,
            is_intro: false,
            is_unsynced: false,
            is_interlude: false,
            peeked_ahead: false,
            active_word_index: -1,
            active_word_progress: 0.0,
            active_word_before_start: false,
            active_word_after_end: false,
            line_changed: false,
            transition_progress: 1.0,
            animated_orb_alpha: 0.0,
            art_scale: 1.0,
            art_opacity: 1.0,
            needs_active_frames: false,
            is_sparkling_candidate: false,
            sparkle_cycle_time: 0.0,
        };
        let Some(core) = (unsafe { handle.as_ref() }) else {
            return empty;
        };
        let lines = core.lyrics.snapshot();
        let is_loading = core.lyrics.is_loading.load(Ordering::Acquire);
        let Ok(mut pb) = core.playback.lock() else {
            return empty;
        };
        let Some(res) =
            pb.step_menubar_frame(&lines, dt, now_mono, now_unix, is_loading, is_ultra_light)
        else {
            return empty;
        };
        CFfiMenuBarFrame {
            has_track: true,
            text_ptr: to_cstring_raw(&res.text),
            line_id: res.line_id,
            progress: res.progress,
            is_intro: res.is_intro,
            is_unsynced: res.is_unsynced,
            is_interlude: res.is_interlude,
            peeked_ahead: res.peeked_ahead,
            active_word_index: res.active_word_index,
            active_word_progress: res.active_word_progress,
            active_word_before_start: res.active_word_before_start,
            active_word_after_end: res.active_word_after_end,
            line_changed: res.line_changed,
            transition_progress: res.transition_progress,
            animated_orb_alpha: res.animated_orb_alpha,
            art_scale: res.art_scale,
            art_opacity: res.art_opacity,
            needs_active_frames: res.needs_active_frames,
            is_sparkling_candidate: res.is_sparkling_candidate,
            sparkle_cycle_time: res.sparkle_cycle_time,
        }
    }))
    .unwrap_or(CFfiMenuBarFrame {
        has_track: false,
        text_ptr: ptr::null_mut(),
        line_id: 0,
        progress: 0.0,
        is_intro: false,
        is_unsynced: false,
        is_interlude: false,
        peeked_ahead: false,
        active_word_index: -1,
        active_word_progress: 0.0,
        active_word_before_start: false,
        active_word_after_end: false,
        line_changed: false,
        transition_progress: 1.0,
        animated_orb_alpha: 0.0,
        art_scale: 1.0,
        art_opacity: 1.0,
        needs_active_frames: false,
        is_sparkling_candidate: false,
        sparkle_cycle_time: 0.0,
    })
}

// MARK: - Color Extraction & Artwork Networking

#[no_mangle]
pub extern "C" fn lyrics_core_extract_waveform_theme_rgba(
    rgba_ptr: *const u8,
    width: usize,
    height: usize,
) -> CFfiWaveformTheme {
    let theme = catch_unwind(AssertUnwindSafe(|| {
        if rgba_ptr.is_null() || width == 0 || height == 0 {
            return WaveformTheme::default();
        }
        let len = width.saturating_mul(height).saturating_mul(4);
        let slice = unsafe { slice::from_raw_parts(rgba_ptr, len) };
        extract_waveform_theme_rgba(slice, width, height)
    }))
    .unwrap_or_default();

    CFfiWaveformTheme {
        top: CFfiRgbaColor {
            r: theme.top.r,
            g: theme.top.g,
            b: theme.top.b,
            a: theme.top.a,
        },
        bottom: CFfiRgbaColor {
            r: theme.bottom.r,
            g: theme.bottom.g,
            b: theme.bottom.b,
            a: theme.bottom.a,
        },
        glow: CFfiRgbaColor {
            r: theme.glow.r,
            g: theme.glow.g,
            b: theme.glow.b,
            a: theme.glow.a,
        },
        accent: CFfiRgbaColor {
            r: theme.accent.r,
            g: theme.accent.g,
            b: theme.accent.b,
            a: theme.accent.a,
        },
    }
}

#[no_mangle]
pub extern "C" fn lyrics_core_sanitize_artwork_url(url: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { cstr_to_string(url) };
        sanitize_artwork_url(&s)
            .map(|out| to_cstring_raw(&out))
            .unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn lyrics_core_download_bytes(
    url: *const c_char,
    timeout_secs: u64,
) -> CFfiByteBuffer {
    catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { cstr_to_string(url) };
        if let Some(mut v) = download_url_bytes(
            &s,
            timeout_secs,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        ) {
            v.shrink_to_fit();
            let len = v.len();
            let ptr = v.as_mut_ptr();
            std::mem::forget(v);
            CFfiByteBuffer { data: ptr, len }
        } else {
            CFfiByteBuffer {
                data: ptr::null_mut(),
                len: 0,
            }
        }
    }))
    .unwrap_or(CFfiByteBuffer {
        data: ptr::null_mut(),
        len: 0,
    })
}

#[no_mangle]
pub extern "C" fn lyrics_core_fetch_itunes_artwork(
    track: *const c_char,
    artist: *const c_char,
) -> CFfiByteBuffer {
    catch_unwind(AssertUnwindSafe(|| {
        let t = unsafe { cstr_to_string(track) };
        let a = unsafe { cstr_to_string(artist) };
        if let Some(mut v) = fetch_itunes_artwork_bytes(&t, &a) {
            v.shrink_to_fit();
            let len = v.len();
            let ptr = v.as_mut_ptr();
            std::mem::forget(v);
            CFfiByteBuffer { data: ptr, len }
        } else {
            CFfiByteBuffer {
                data: ptr::null_mut(),
                len: 0,
            }
        }
    }))
    .unwrap_or(CFfiByteBuffer {
        data: ptr::null_mut(),
        len: 0,
    })
}

// MARK: - Remote Config & OTA Updater

pub type UpdateCheckCallback = extern "C" fn(ctx: usize, outcome_json: *mut c_char);
pub type DownloadProgressCallback = extern "C" fn(ctx: usize, progress: f64);
pub type DownloadCompleteCallback =
    extern "C" fn(ctx: usize, success: bool, error_msg: *mut c_char);

#[no_mangle]
pub extern "C" fn lyrics_core_is_version_greater(
    remote: *const c_char,
    local: *const c_char,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let r = unsafe { cstr_to_string(remote) };
        let l = unsafe { cstr_to_string(local) };
        is_version_greater(&r, &l)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn lyrics_core_check_updates_async(
    current_version: *const c_char,
    current_build: i32,
    ctx: usize,
    callback: UpdateCheckCallback,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let ver = unsafe { cstr_to_string(current_version) };
        let _ = thread::Builder::new()
            .name("lyrics-updater-check".into())
            .spawn(move || {
                let outcome = check_updates(&ver, current_build);
                let json = serde_json::to_string(&outcome).unwrap_or_else(|_| "{}".to_string());
                callback(ctx, to_cstring_raw(&json));
            });
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_download_dmg_async(
    handle: *mut LyricsCoreHandle,
    url: *const c_char,
    dest_path: *const c_char,
    ctx: usize,
    progress_cb: DownloadProgressCallback,
    complete_cb: DownloadCompleteCallback,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = (unsafe { handle.as_ref() }) else {
            complete_cb(ctx, false, to_cstring_raw("Invalid core handle"));
            return;
        };
        core.download_cancel.store(false, Ordering::Release);
        let cancel = core.download_cancel.clone();
        let url_str = unsafe { cstr_to_string(url) };
        let dest_str = unsafe { cstr_to_string(dest_path) };

        let _ = thread::Builder::new()
            .name("lyrics-dmg-download".into())
            .spawn(move || {
                match download_dmg_streaming(&url_str, &dest_str, &cancel, |p| {
                    progress_cb(ctx, p);
                }) {
                    Ok(()) => complete_cb(ctx, true, ptr::null_mut()),
                    Err(e) => complete_cb(ctx, false, to_cstring_raw(&e)),
                }
            });
    }));
}

#[no_mangle]
pub extern "C" fn lyrics_core_cancel_download(handle: *mut LyricsCoreHandle) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(core) = unsafe { handle.as_ref() } {
            core.download_cancel.store(true, Ordering::Release);
        }
    }));
}
