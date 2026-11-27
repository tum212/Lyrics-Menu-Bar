#ifndef LYRICS_CORE_H
#define LYRICS_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LyricsCoreHandle LyricsCoreHandle;
typedef struct LyricsAudioHandle LyricsAudioHandle;
typedef struct LyricsHapticsHandle LyricsHapticsHandle;

typedef struct CFfiRgbaColor {
    float r;
    float g;
    float b;
    float a;
} CFfiRgbaColor;

typedef struct CFfiWaveformTheme {
    CFfiRgbaColor top;
    CFfiRgbaColor bottom;
    CFfiRgbaColor glow;
    CFfiRgbaColor accent;
} CFfiWaveformTheme;

typedef struct CFfiPlaybackDelta {
    bool track_changed;
    bool artwork_url_changed;
    bool play_state_changed;
    bool source_changed;
} CFfiPlaybackDelta;

typedef struct CFfiMenuBarFrame {
    bool has_track;
    char *text_ptr;
    uint64_t line_id;
    double progress;
    bool is_intro;
    bool is_unsynced;
    bool is_interlude;
    bool peeked_ahead;
    int32_t active_word_index;
    double active_word_progress;
    bool active_word_before_start;
    bool active_word_after_end;
    bool line_changed;
    double transition_progress;
    double animated_orb_alpha;
    double art_scale;
    double art_opacity;
    bool needs_active_frames;
    bool is_sparkling_candidate;
    double sparkle_cycle_time;
} CFfiMenuBarFrame;

typedef struct CFfiByteBuffer {
    uint8_t *data;
    size_t len;
} CFfiByteBuffer;

typedef void (*CHHapticFallbackFn)(void *ctx, double delay_secs, bool is_deep, int32_t intensity);
typedef void (*LyricsReadyCallback)(uintptr_t ctx, uint64_t request_id);
typedef void (*UpdateCheckCallback)(uintptr_t ctx, char *outcome_json);
typedef void (*DownloadProgressCallback)(uintptr_t ctx, double progress);
typedef void (*DownloadCompleteCallback)(uintptr_t ctx, bool success, char *error_msg);

// Memory management
void lyrics_core_free_string(char *ptr);
void lyrics_core_free_bytes(CFfiByteBuffer buf);

// Core lifecycle
LyricsCoreHandle *lyrics_core_create(void);
void lyrics_core_destroy(LyricsCoreHandle *handle);

// Audio DSP
LyricsAudioHandle *lyrics_core_audio_create(void);
void lyrics_core_audio_destroy(LyricsAudioHandle *handle);
void lyrics_core_audio_update_band_count(LyricsAudioHandle *handle, int32_t band_count);
void lyrics_core_audio_reset(LyricsAudioHandle *handle);
void lyrics_core_audio_process_pcm(
    LyricsAudioHandle *handle,
    const float *left,
    const float *right,
    size_t frame_or_float_len,
    size_t channels,
    float sample_rate,
    uint64_t output_host_time,
    int32_t haptic_intensity,
    const LyricsHapticsHandle *haptics_handle
);
size_t lyrics_core_audio_tick_bars(
    LyricsAudioHandle *handle,
    double delta_time,
    double now_unix,
    bool is_playing,
    bool is_tap_running,
    size_t bar_count,
    float *out_heights,
    size_t out_capacity
);

// Haptics
LyricsHapticsHandle *lyrics_core_haptics_create(void);
void lyrics_core_haptics_destroy(LyricsHapticsHandle *handle);
bool lyrics_core_haptics_has_multitouch(const LyricsHapticsHandle *handle);
void lyrics_core_haptics_set_actuator_type(const LyricsHapticsHandle *handle, int32_t actuator_type);
void lyrics_core_haptics_set_latency_offset(const LyricsHapticsHandle *handle, double offset_secs);
void lyrics_core_haptics_set_fallback(
    const LyricsHapticsHandle *handle,
    CHHapticFallbackFn callback,
    void *ctx
);
void lyrics_core_haptics_test_type(const LyricsHapticsHandle *handle, int32_t actuator_type);

// Lyrics Engine
void lyrics_core_lyrics_set_endpoints(
    LyricsCoreHandle *handle,
    const char *lrclib_search,
    const char *lrclib_get,
    const char *lyrics_ovh
);
void lyrics_core_lyrics_clear(LyricsCoreHandle *handle);
bool lyrics_core_lyrics_fetch(
    LyricsCoreHandle *handle,
    const char *track,
    const char *artist,
    const char *album,
    uintptr_t ctx,
    LyricsReadyCallback callback
);
bool lyrics_core_lyrics_is_loading(const LyricsCoreHandle *handle);
char *lyrics_core_lyrics_get_json(const LyricsCoreHandle *handle);

// Playback & Menu Bar State Machine
CFfiPlaybackDelta lyrics_core_playback_update(
    LyricsCoreHandle *handle,
    const char *id,
    const char *name,
    const char *artist,
    const char *album,
    const char *artwork_url,
    double duration,
    double position,
    bool is_playing,
    const char *source_id,
    double now_mono,
    double now_unix
);
bool lyrics_core_playback_mark_stopped(
    LyricsCoreHandle *handle,
    const char *source_id,
    int32_t threshold,
    bool is_not_running
);
double lyrics_core_playback_current_time(LyricsCoreHandle *handle, double now_mono);
void lyrics_core_playback_seek_local(LyricsCoreHandle *handle, double target_time, double now_mono);
void lyrics_core_playback_set_playing_local(LyricsCoreHandle *handle, bool is_playing, double now_mono);
int32_t lyrics_core_playback_hud_active_index(
    LyricsCoreHandle *handle,
    double now_mono,
    bool *out_is_unsynced
);
CFfiMenuBarFrame lyrics_core_menubar_step(
    LyricsCoreHandle *handle,
    double dt,
    double now_mono,
    double now_unix,
    bool is_ultra_light
);

// Color Extraction & Artwork Networking
CFfiWaveformTheme lyrics_core_extract_waveform_theme_rgba(
    const uint8_t *rgba_ptr,
    size_t width,
    size_t height
);
char *lyrics_core_sanitize_artwork_url(const char *url);
CFfiByteBuffer lyrics_core_download_bytes(const char *url, uint64_t timeout_secs);
CFfiByteBuffer lyrics_core_fetch_itunes_artwork(const char *track, const char *artist);

// Remote Config & OTA Updater
bool lyrics_core_is_version_greater(const char *remote, const char *local);
void lyrics_core_check_updates_async(
    const char *current_version,
    int32_t current_build,
    uintptr_t ctx,
    UpdateCheckCallback callback
);
void lyrics_core_download_dmg_async(
    LyricsCoreHandle *handle,
    const char *url,
    const char *dest_path,
    uintptr_t ctx,
    DownloadProgressCallback progress_cb,
    DownloadCompleteCallback complete_cb
);
void lyrics_core_cancel_download(LyricsCoreHandle *handle);

#ifdef __cplusplus
}
#endif

#endif /* LYRICS_CORE_H */
