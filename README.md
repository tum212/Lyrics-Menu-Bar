# Lyrics Menu Bar

<p align="center">
  <img src="docs/images/app_icon.png" width="140" height="140" alt="Lyrics Menu Bar Icon">
</p>

<p align="center">
  <strong>v2.0.0 — Rust Core Engine + Pure AppKit 60 FPS Universal Lyrics, Floating Glass HUD, Process-Tree Audio Visualizer &amp; Force Touch Haptics for macOS 13.0+.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2013.0%2B-blue?style=flat-square&logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Core-Rust%20Staticlib-DEA584?style=flat-square&logo=rust" alt="Rust">
  <img src="https://img.shields.io/badge/UI-Pure%20AppKit%20%2F%20CALayer-orange?style=flat-square&logo=swift" alt="AppKit">
  <img src="https://img.shields.io/badge/SwiftUI-0%25-brightgreen?style=flat-square" alt="Zero SwiftUI">
  <img src="https://img.shields.io/badge/Release-v2.0.0-emerald?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon%20%2F%20Intel-purple?style=flat-square" alt="Arch">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
</p>

<p align="center">
  <img src="docs/images/benchmark_hero.png" width="100%" alt="Lyrics Menu Bar Screenshot">
</p>

---

## Table of Contents
- [What's New in v2.0.0](#whats-new-in-v200)
- [Universal Multi-App & Web Streaming Support](#universal-multi-app--web-streaming-support)
- [Why Rust + Pure AppKit? (Performance & Architecture)](#why-rust--pure-appkit-performance--architecture)
- [Core Features](#core-features)
- [macOS Compatibility](#macos-compatibility)
- [Installation (Zero Runtime Dependencies)](#installation-zero-runtime-dependencies)
- [Building from Source](#building-from-source)
- [Repository Structure](#repository-structure)
- [License](#license)

---

## What's New in v2.0.0

- **Rust Core Engine (`liblyrics_core.a`)**: Rebuilt the entire DSP, haptics, lyrics parsing/fetching, playback clock, color extraction, and OTA updater engine in Rust — compiled ahead-of-time into a universal Mach-O static library embedded inside the single executable (**no Rust/Xcode runtime required on user Macs**).
- **100% Zero-SwiftUI Pure AppKit / `CALayer` UI**: Eliminated SwiftUI (`SwiftUICore`, `NSHostingView`, `TimelineView`) completely for locked **60 FPS VSync** smoothness even on fanless Intel Macs such as the **MacBook 12" (2017 Core m3)**, with **`0 Hz` / `0%` CPU** when paused or idle.
- **Universal Multi-App & Web Streaming Engine**: Goes far beyond Spotify & Apple Music — now supports **YouTube Music (Desktop & Web)**, **TIDAL**, **Deezer**, **Qobuz**, **Amazon Music**, **SoundCloud**, **Cider**, **Swinsian**, **VOX**, **VLC**, **Doppler**, **Cog**, **IINA**, **Bandcamp**, and **YouTube** across **Safari, Chrome, Brave, Arc, Edge, Vivaldi, Opera, and Firefox**.
- **Process-Tree CoreAudio Tap**: Automatically discovers Electron, Chromium, and Safari `WebKit.GPU` / `WebKit.WebContent` helper subprocesses so the real-time waveform visualizer & Force Touch beat haptics work across desktop apps and web browsers alike.
- **Auto-Fade Hover HUD Controls**: Top-right Settings (`...`) and Close (`^`) glass buttons stay unobtrusively hidden while reading lyrics, fade smoothly in on mouse hover/movement, and fade back out after 2 seconds of stillness.
- **Multilingual Typography & Thai/CJK Precision**: 22pt menu bar text clearance prevents upper Thai tone mark clipping, grapheme-safe HUD line wrapping handles unspaced Thai/CJK scripts cleanly, and fuzzy lyric matching preserves Thai vowels/tones and Japanese dakuten.

---

## Universal Multi-App & Web Streaming Support

Lyrics Menu Bar v2.0.0 uses a **3-layer sanctioned macOS detection engine** with strict **Playing > Sticky Paused** arbitration (a paused background player never hijacks an active stream):

| Layer | Supported Players & Services | How It Works |
| :--- | :--- | :--- |
| **Layer 1 — Native & Local API** | **Spotify**, **Apple Music**, **Swinsian**, **VOX**, **VLC**, **YouTube Music Desktop (Pear / th-ch `:26538`)**, **YTMDesktop (`:9863`)**, **Cider (`:10767`)** | `DistributedNotificationCenter` + single serial `OSAScriptExecutor` + official localhost APIs |
| **Layer 2 — In-Process MediaRemote** | All Now Playing apps & browsers on **macOS 13.0–15.3** | Direct in-process `MediaRemote.framework` (`dlopen`), gracefully stands down with 0 overhead on macOS 15.4+ |
| **Layer 3 — Web Players & Desktop Apps** | **YouTube Music Web**, **Spotify Web**, **Apple Music Web**, **SoundCloud**, **TIDAL**, **Deezer**, **Qobuz**, **Amazon Music**, **Bandcamp**, **YouTube**, **Doppler**, **Cog**, **IINA** in **Safari, Chrome, Brave, Arc, Edge, Vivaldi, Opera, Firefox** | Sanctioned browser tab/MediaSession reading + cached **YouTube oEmbed** metadata resolver (for single-title Art Tracks) + `CGWindowListCopyWindowInfo` + CoreAudio `kAudioProcessPropertyIsRunningOutput` active-audio detection |

Select **`Auto (Detect Any Player)`** or lock to any installed app / web browser under **Settings → General → Music Source** (live running apps are marked with `●`).

---

## Why Rust + Pure AppKit? (Performance & Architecture)

Built with an **"Apollo 11 / 4KB-to-the-Moon"** engineering standard: respect the user's hardware, eliminate framework bloat, and never drop frame rates to hide inefficiency.

| Metric / Subsystem | v1.x (SwiftUI + `NSHostingView`) | v2.0.0 (Rust Core + Pure AppKit / `CALayer`) |
| :--- | :--- | :--- |
| **UI Framework** | SwiftUI + `NSHostingView` + `TimelineView` | **0% SwiftUI** — Pure AppKit + GPU `CALayer` |
| **Audio FFT & Beat Engine** | Swift `vDSP` + main-thread timers | **Rust `realfft` 4096-pt** (zero-alloc RT PCM ring buffer) |
| **Networking & TLS** | `URLSession` + Swift `Task` fan-out | **Rust `ureq` + shared `native-tls` keep-alive pool** |
| **Lyrics Parsing & Timing** | Swift regex / per-frame `UserDefaults` | **Rust LRC/eLRC/TTML/Plain + 100-entry `Arc` LRU cache** |
| **Menu Bar Rendering** | Frequent redraws / SwiftUI layout passes | **Rasterize once to Retina `CGImage` → GPU-only 60 FPS wipe/slide** |
| **Idle / Paused CPU & VRAM** | Periodic timers & retained SwiftUI tree | **`0 Hz` `CVDisplayLink` sleep + HUD texture cache purged on close** |
| **MacBook 12" (2017 Core m3)** | Heavy glass + SwiftUI frame drops | **Locked 60 FPS VSync** with Auto-ON Lightweight Mode |
| **End-User Runtime Requirement** | macOS 13+ | **macOS 13+ only** (`liblyrics_core.a` statically linked — **zero Rust install needed**) |

### Adaptive Performance Modes
- **Standard Glass Mode**: Multi-pass `CABackdropLayer` saturation vibrancy, specular edge highlights, 3D Genie panel spring, and subtle singing lyric glow.
- **Reduce Glass & Blur Effects (60 FPS Lightweight)**: Automatically enabled on **Intel (`x86_64`) Macs**, **macOS 13 Ventura**, and **macOS Low Power Mode** (always toggleable in **Settings → Appearance & Performance**). Uses single-pass native `NSVisualEffectView` + 2D `CASpringAnimation` to preserve Intel iGPU bandwidth while keeping full **60 FPS** karaoke wipes, marquee scrolling, and click-to-seek.

---

## Core Features

### Real-Time Menu Bar Lyrics
- Synchronized word/syllable karaoke highlighting (`CAGradientLayer` feather mask) with automatic fallback for line-synced and plain lyrics.
- Animated 3-star interlude indicator (`✦ ✦ ✦`) during instrumental breaks, marquee scrolling within notch-safe screen budgets, and clickable `play.fill` fallback when idle or all strip elements are toggled off.

<p align="center">
  <img src="docs/images/menubar_interlude_stars.gif" width="100%" alt="Menu Bar Lyrics and Interlude Indicator">
</p>

### Dynamic Audio Visualizer *(macOS 14.2+)*
- Real-time logarithmic frequency spectrum (60 Hz – 16 kHz, Bluetooth HFP 16 kHz safe) rendered in the menu bar with true-tone 12-hue-bucket colors extracted from the album cover.
- Configurable bar counts (`Off`, `6`, `10`, `14`, `24`, `32`, `48`, or custom up to `128` bars) with zero per-frame heap allocations at 60 FPS.

<p align="center">
  <img src="docs/images/menubar_lyrics_and_waveform.gif" width="100%" alt="Menu Bar Audio Visualizer and Lyrics">
</p>

### Floating Dark-Glass HUD
- Click the menu bar strip to open the floating dark-glass HUD panel (locked to `.darkAqua` so white typography stays crisp in both macOS Dark and Light Mode, across all Spaces and Full-Screen apps).
- Virtualized `HUDLyricsView` (18 recycled `CALayer` slots) with critically-damped Apple Music scroll physics, Focus Mode depth, **click-to-seek** on any line, and hover auto-fading `...` / `^` top-right controls.
- Album art & track info click-through opens the currently active player or browser directly.

<p align="center">
  <img src="docs/images/lyrics_window_singing.gif" width="100%" alt="Lyrics HUD Window">
</p>

### Force Touch Trackpad Haptics *(macOS 14.2+)*
- Dedicated Rust `Condvar` scheduler driving `MultitouchSupport.framework` (`MTActuatorActuate` via `IOKit`) with calibrated 5ms acoustic lead time and Mach host-time synchronization, plus automatic `CHHapticEngine` fallback on hardware without Force Touch.
- Selectable intensity (`Off`, `Light`, `Medium`, `Firm`) and actuator feel (`Auto`, `Type 1`–`Type 6`, plus live feel tester).

### Streaming In-App OTA Updates & Remote Config
- Checks `remote_config.json` and GitHub Releases (`v2.0.0`) with proper semver pre-release handling, atomic `.part` DMG streaming download, `codesign --verify --deep --strict` verification before swap, and 1-click relaunch.

---

## macOS Compatibility

Unsupported macOS 14.2+ tap features are automatically greyed out on macOS 13 Ventura:

| Feature | macOS 13.0+ (Ventura) | macOS 14.2+ (Sonoma / Sequoia / Tahoe) |
|---|:---:|:---:|
| 60 FPS Rust + `CALayer` Menu Bar Lyrics & Marquee | Supported | Supported |
| 60 FPS Floating Dark-Glass HUD & Word Karaoke | Supported | Supported |
| Universal Multi-App & Web Browser Support | Supported | Supported |
| Click-to-Seek & Unified Playback Controls | Supported | Supported |
| Reduce Glass & Blur Effects (60 FPS Lightweight) | Auto-ON (Toggleable) | Auto on Intel / Low Power |
| Live CoreAudio Process-Tree Tap Visualizer | Greyed out (`Requires macOS 14.2+`) | Supported |
| Force Touch Beat-Synced Haptics | Greyed out (`Requires macOS 14.2+`) | Supported |

---

## Installation (Zero Runtime Dependencies)

> [!NOTE]
> **End users do NOT need Rust, Cargo, or Xcode installed.** The Rust engine is statically compiled into the universal macOS executable (`otool -L` links only standard macOS system frameworks).

1. Download **`LyricsMenuBar-2.0.0.dmg`** (~7.5 MB Universal `arm64` + `x86_64`) from [GitHub Releases](https://github.com/tum212/Lyrics-Menu-Bar/releases).
2. Drag **Lyrics Menu Bar** into `/Applications`.
3. Open **Lyrics Menu Bar** from `/Applications` or Spotlight and allow **Automation** permissions when prompted *(and **System Audio Recording** on macOS 14.2+ if using the live waveform visualizer or haptics)*.

> [!TIP]
> **If macOS Gatekeeper blocks first launch (ad-hoc signed open-source build):**  
> Right-click **Lyrics Menu Bar** in `/Applications` → **Open**, or run:
> ```bash
> xattr -cr "/Applications/Lyrics Menu Bar.app"
> ```

---

## Building from Source

```bash
# 1. Install Rust toolchain with Apple Silicon + Intel macOS targets
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# 2. Clone the repository
git clone https://github.com/tum212/Lyrics-Menu-Bar.git
cd Lyrics-Menu-Bar

# 3. Run Rust unit tests (18 tests)
cargo test --manifest-path rust/lyrics-core/Cargo.toml

# 4. Build Universal Rust staticlib + Universal macOS DMG (arm64 + x86_64, macOS 13.0+)
bash build_dmg.sh
```

---

## Repository Structure

```text
SpoticatMenuBar/
├── Package.swift                       # Swift 6 Package manifest (CLyricsCore + Pure AppKit macOS 13.0+)
├── build_dmg.sh                        # Strict (set -euo pipefail) Universal Rust + Swift DMG packager
├── LyricsMenuBar.entitlements          # Hardened runtime & CoreAudio entitlements
├── remote_config.json                  # Remote OTA version & lyrics endpoints config
├── icon.icns                           # Application icon
├── docs/images/                        # Screenshots and demo GIFs
├── rust/lyrics-core/                   # Rust staticlib Core Engine (liblyrics_core.a)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs & ffi.rs             # Shared native-tls pool, C ABI exports & panic-safe FFI
│       ├── dsp.rs                      # Zero-alloc 4096-pt realfft DSP & ballistic equalizer physics
│       ├── haptics.rs                  # Condvar MultitouchSupport / IOKit beat-synced Force Touch haptics
│       ├── lyrics.rs                   # LRC/eLRC/TTML/Plain parsers, Thai/CJK handling & Arc LRU cache
│       ├── playback.rs                 # Dynamic source_id monotonic clock & Menu Bar state machine
│       ├── color.rs                    # 12-hue album palette extractor & artwork networking
│       └── updater.rs                  # Semver remote config & atomic streaming OTA DMG downloader
├── Sources/
│   ├── CLyricsCore/include/
│   │   ├── lyrics_core.h               # C header for Swift/Clang FFI interop
│   │   └── module.modulemap
│   └── LyricsMenuBar/                  # Zero-SwiftUI AppKit / CALayer Shell
│       ├── Info.plist                  # Universal bundle metadata (v2.0.0, LSMinimumSystemVersion 13.0)
│       ├── AppSettings.swift           # Capability detection, Lightweight defaults & setting keys
│       ├── MusicSourceRegistry.swift   # 20+ player & 10-domain web parser registry + YouTube ID extractor
│       ├── RustBridge.swift            # Swift facade over liblyrics_core.a, ArtworkCache & OTA installer
│       ├── LyricsMenuBarApp.swift      # App entry point, 60 FPS CVDisplayLink, Sleep/Wake & Genie panel
│       ├── MenuBarCanvasView.swift     # GPU-native 22pt CALayer menu bar renderer
│       ├── HUDGlassView.swift          # Adaptive dark-glass NSVisualEffectView / CABackdropLayer backdrop
│       ├── HUDContentView.swift        # Pure AppKit 480x240 HUD, hover auto-fade controls & Update modal
│       ├── HUDLyricsView.swift         # Virtualized 60 FPS CALayer karaoke stream with Thai/CJK wrap
│       ├── SettingsMenuController.swift# Dynamic multi-app NSMenu settings with modal depth tracking
│       ├── AudioTapBridge.swift        # Serial HAL Process-Tree CoreAudio Tap -> Rust DSP (macOS 14.2+)
│       ├── MusicIPCBridge.swift        # 3-layer Universal IPC + YouTube oEmbed + serial OSA executor
│       └── LaunchAtLoginManager.swift  # SMAppService login item manager
└── README.md                           # Documentation & GitHub landing page
```

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
