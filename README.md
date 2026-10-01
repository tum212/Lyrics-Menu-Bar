# 🎵 Lyrics Menu Bar (macOS)

<p align="center">
  <img src="docs/images/app_icon.png" width="140" height="140" alt="Lyrics Menu Bar Icon">
</p>

<p align="center">
  <b>The ultimate real-time lyrics, native glass visualizer & haptic companion for macOS menu bar.</b><br>
  Engineered with Apple Music precision • Silky 60 FPS • Private APIs & deep mathematical modeling
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.2%2B-blue?style=flat-square&logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.10-orange?style=flat-square&logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/Release-v1.2.0-emerald?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon%20%2F%20Intel-purple?style=flat-square" alt="Arch">
  <img src="https://img.shields.io/badge/Private%20APIs-CoreAudio%20Tap%20%7C%20MultitouchSupport-red?style=flat-square" alt="APIs">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
</p>

---

## 📑 Table of Contents
- [The Engineering Philosophy & Benchmark](#the-engineering-philosophy--benchmark)
- [Key Features](#key-features)
  - [1. Real-Time Menu Bar Lyrics & Melody Stars](#1-real-time-menu-bar-lyrics--melody-stars)
  - [2. Dynamic Equalizer Waveform](#2-dynamic-equalizer-waveform)
  - [3. Native Translucent Glass HUD](#3-native-translucent-glass-hud)
  - [4. Force Touch Hardware Haptic Subwoofer](#4-force-touch-hardware-haptic-subwoofer)
- [Core Subsystems & Private macOS APIs](#core-subsystems--private-macos-apis)
- [Mathematical Models Across Every Function](#mathematical-models-across-every-function)
- [Target Communities](#target-communities)
- [Installation & macOS Permissions](#installation--macos-permissions)
- [Building from Source](#building-from-source)
- [Repository Architecture](#repository-architecture)
- [License](#license)

---

## The Engineering Philosophy & Benchmark

The goal of **Lyrics Menu Bar** is to create an omnipresent, zero-footprint desktop music companion that bridges typography, real-time audio visualization, and tactile feedback directly in your macOS menu bar.

<p align="center">
  <img src="docs/images/benchmark_hero.png" width="100%" alt="Lyrics Menu Bar Benchmark">
</p>

### The Benchmark: Lorde - "No Better"
During months of architectural development, Lorde's single *"No Better"* served as the definitive benchmark:
1. **High Syllabic Velocity:** The vocal track features rapid-fire contiguous phonemes, serving as a stress test for our sub-millisecond typographic rendering pipeline.
2. **Dynamic Low-End Transients:** Sub-bass fundamentals test the CoreAudio FFT band separation and physical Force Touch motor timing.
3. **Underwater Teal Palette:** The album artwork's signature teal tones challenged our color extraction pipeline to achieve pristine glass translucency without muddy grayscale artifacts.

> *"We roll in every summer when there's strength in our numbers  
> And your breath's hot and gross, but I kiss you like a lover  
> Legs stick to the seats of the car someone grew into  
> I forget the knowledge from the lessons that I went to..."*

---

## Key Features

### 1. Real-Time Menu Bar Lyrics & Melody Stars

<p align="center">
  <img src="docs/images/menubar_interlude_stars.gif" width="100%" alt="Menu Bar Real-Time Melody Interlude Stars">
</p>

- **Melody Interlude Stars (✦ ✦ ✦):** During instrumental solos or vocal pauses, pulsing triple stars maintain visual rhythm, signaling when the next phrase is about to start.
- **60 FPS Mathematical Smoothness:** Every syllable is phonetically weighted, rendering with analog continuity at near-zero CPU footprint.
- **Synced & Unsynced Resilience:** Syllabic-accurate real-time karaoke for synchronized tracks, with smooth auto-scroll fallbacks for unsynced tracks.

---

### 2. Dynamic Equalizer Waveform

<p align="center">
  <img src="docs/images/menubar_lyrics_and_waveform.gif" width="100%" alt="Menu Bar Real-Time Dynamic Island Waveform & Lyrics">
</p>

- **Configurable Waveform Density:** Choose from 8, 14, 20, or up to 128 dynamic equalizer bars.
- **Modular Visibility:** Display lyrics, audio spectrum, cover art, or any combination seamlessly in the menu bar.
- **Native Integration:** Curvature, spacing, and vibrancy calibrated to match native macOS menu bar aesthetics.

---

### 3. Native Translucent Glass HUD

<p align="center">
  <img src="docs/images/lyrics_window_singing.gif" width="100%" alt="Native Glass Window Phosphorescence Glow Animation">
</p>

Clicking the menu bar item unveils the floating glass HUD:
- **Playback Controls:** Rounded glass buttons for Previous, Play/Pause, and Next.
- **Phosphorescent Glow Decay:** Completed words gently fade over a 320ms curve rather than abruptly extinguishing, creating a natural illumination handoff.
- **Click-to-Seek:** Click any lyric line to jump directly to that timestamp in Apple Music or Spotify with haptic confirmation.
- **Adaptive Transparency:** Automatically blends desktop tones and wallpaper hues with specular edge highlights.

---

### 4. Force Touch Hardware Haptic Subwoofer

Porting Apple's iOS Taptic experience to the **MacBook Force Touch Trackpad**:
- **Acoustic-to-Tactile Transduction:** Intercepts real-time audio streams, analyzes low frequencies and kick transients, and pulses the trackpad actuator.
- **Zero-Latency Hardware Synchronization:** Incorporates a 5ms lead-time offset so the physical vibration strikes your fingers at the exact moment sound reaches your ears.
- **Configurable Intensity:** Off, Subtle, Medium, or Strong haptic feedback.

---

## Core Subsystems & Private macOS APIs

### 1. Force Touch Trackpad Actuation (`MultitouchSupport.framework`)
Instead of high-latency AppKit haptic abstractions, Lyrics Menu Bar directly invokes private symbols inside Apple's `MultitouchSupport.framework`:
- Dynamically resolved via `dlopen`: `MTActuatorCreateFromDeviceID`, `MTActuatorOpen`, and `MTActuatorActuate`.
- Hardware device identification resolved through `IOKit` matching `AppleMultitouchDevice`.
- **Zero-Latency Lead Time Theorem:**
  $$T_{\text{haptic}} = T_{\text{dac}} - (\text{Latency}_{\text{hw}} - \text{Latency}_{\text{acoustic}}) = T_{\text{dac}} - (6\,\text{ms} - 1\,\text{ms}) = T_{\text{dac}} - 5\,\text{ms}$$
  The haptic impulse is fired 5ms ahead of the DAC hardware presentation time, ensuring tactile vibration strikes the user's fingers at the exact moment acoustic waves reach the eardrum.

### 2. CoreAudio HAL Process Tap
- Uses modern macOS HAL tap APIs: `AudioObjectPropertyAddress` targeting `kAudioTapPropertyUID` and `AudioObjectCreateProcessTap`.
- Intercepts raw 32-bit floating-point audio frames directly from Spotify and Apple Music processes.
- **Zero Virtual Audio Drivers:** Requires no external kexts, virtual audio loopbacks, or system extensions (e.g., BlackHole / Soundflower).

### 3. Native Glass Compositor
- Native `NSVisualEffectView` with `.behindWindow` blending and `.popover` material coupled with `CABackdropLayer` saturation enhancement.
- Pure GPU compositor rendering with specular optical rim gradients, naturally adapting over both dark wallpapers and bright browser windows.

<p align="center">
  <img src="docs/images/lyrics_window_singing.gif" width="100%" alt="Native Glass Window Phosphorescence Glow">
</p>

### 4. Monotonic Jitter-Free IPC Clock
- Apple Music ScriptingBridge reports playback timestamps quantized to 1-second intervals.
- Lyrics Menu Bar synthesizes continuous high-resolution time:
  $$t_{\text{current}} = t_{\text{polled}} + (t_{\text{now}} - t_{\text{poll}})$$
  enforced with strict monotonic forward clamping:
  $$t_{\text{clamped}} = \max(t_{\text{rendered}}, t_{\text{current}})$$
  eliminating all subpixel backward jitter during 60 FPS redraws.

---

## Mathematical Models Across Every Function

### 1. Phosphorescent Glow Decay Model ($C^1$ Continuity)
$$\text{decayFactor}(t) = \frac{1 + \cos\left(\min\left(1, \frac{t - t_{\text{end}}}{\tau}\right) \cdot \pi\right)}{2} \quad (\tau = 0.32\,\text{s})$$

$$\text{GlowOpacity}(t) = 0.35 + 0.40 \cdot \text{decayFactor}(t)$$

$$\text{GlowRadius}(t) = 2.8 + 2.7 \cdot \text{decayFactor}(t)$$

Because $\left.\frac{d}{dt}\cos(t)\right|_{t=0} = -\sin(0) = 0$, the departure velocity at the end of word vocalization is strictly zero, guaranteeing analog illumination handoffs with zero flicker.

### 2. Phonetic Syllable & Musical Weighting
$$\text{Weight}(w) = \left(0.70 \cdot S(w) + 0.08 \cdot C(w) + 0.22\right) \cdot M_{\text{stress}} \cdot M_{\text{punct}} \cdot M_{\text{terminal}}$$
- $S(w)$: Syllable count estimated via phonetic vowel clustering.
- $C(w)$: Character length.
- $M_{\text{stress}} = 0.65$ for unstressed grammatical particles (*a, the, in, to, and*).
- $M_{\text{terminal}} = 1.75$ for pre-pausal lengthening and vocal sustain at phrase endings.

### 3. FFT Audio Spectrum & Equal Loudness Weighting
- In-place split complex FFT via Apple Accelerate (`vDSP_fft_zrip` with 1024-point Hann window).
- Logarithmic bin allocation from 60 Hz to 16,000 Hz.
- Fletcher-Munson perceptual weighting (Sub-bass $0.7\times$, Low-mids $2.2\times$, Presence $3.0\times$, High-mids $2.0\times$, Treble $1.0\times$).
- Asymmetric ballistic filtering:
  $$\text{Gain}_{\text{rise}} = 0.4 \cdot \text{Gain} + 0.6 \cdot \text{Sample}$$
  $$\text{Gain}_{\text{fall}} = 0.96 \cdot \text{Gain} + 0.04 \cdot \text{Sample}$$

<p align="center">
  <img src="docs/images/menubar_lyrics_and_waveform.gif" width="100%" alt="Menu Bar FFT Audio Spectrum & Dynamic Waveform">
</p>

### 4. Adaptive Cover Art Color Blending
- Downsamples album art to a $48 \times 48$ bitmap buffer in `deviceRGB`.
- Filters out shadow mud ($B < 0.12$) and washed-out highlights ($S < 0.15 \land B > 0.88$).
- Weights remaining pixels: $W = S \cdot (1.0 - |B - 0.52| \cdot 0.4)$ into 12 angular hue buckets.
- Synthesizes vibrant tone curves:
  $$S_{\text{vibrant}} = \text{clamp}(0.55, 0.95, S \times 1.25)$$
  $$B_{\text{top}} = \text{clamp}(0.68, 0.94, B \times 1.7 + 0.22)$$
  $$B_{\text{bottom}} = \text{clamp}(0.42, 0.72, B \times 1.35 + 0.08)$$

### 5. $C^1$ Smooth Cubic Hermite Marquee Motion & Interlude Stars
- Marquee text motion follows a cubic Hermite polynomial:
  $$S(x) = 3x^2 - 2x^3$$
  ensuring zero velocity departure and arrival at scroll boundaries.
- Pulsating triple-star interlude indicator (✦ ✦ ✦) keeps visual rhythm during instrumental solos.

<p align="center">
  <img src="docs/images/menubar_interlude_stars.gif" width="100%" alt="Menu Bar Melody Interlude Stars Animation">
</p>

---

## Target Communities

Whether you are looking for clean desk setups, audiophile streaming, or cutting-edge Swift engineering, here is where **Lyrics Menu Bar** fits right in:

- **🛋️ r/macsetups & Aesthetic Workstations:** The missing jewel for clean desk setups. Provides ambient glowing lyrics on the menu bar without cluttering the screen during late-night coding or study sessions (`#desksetup` `#aesthetic` `#lofi`).
- **🕹️ MacBook Taptic Subwoofer Hackers:** An unprecedented hardware innovation that turns the MacBook Force Touch Trackpad into an acoustic bass shaker for your fingertips with zero-latency timing (`#haptic-subwoofer` `#taptic-engine` `#force-touch`).
- **🏝️ Dynamic Island for macOS Lovers:** Bringing the vibrant, real-time music pulse of iPhone's Dynamic Island into the macOS menu bar with 60 FPS elastic spring rebound physics (`#dynamic-island` `#audio-visualizer` `#waveform`).
- **🔮 UI/UX Designers & Shaders Nerds:** True macOS translucent glass HUD with hardware-accelerated vibrancy and adaptive color quantization (`#glassmorphism` `#swiftui`).
- **🎧 r/audiophile & Bit-Perfect Streamers:** Zero-latency direct 32-bit floating-point audio interception via private CoreAudio HAL process taps—no virtual sound cards or audio degradation (`#audiophile` `#lossless` `#coreaudio`).
- **💻 r/SwiftUI & Reverse-Engineering Devs:** A production-grade reference architecture showing how to dynamically invoke private frameworks (`MultitouchSupport`), Mach monotonic clocks, and Accelerate vDSP FFT (`#reverse-engineering` `#private-api` `#swiftui`).

```
# Discovery Topics:
dynamic-island, haptic-subwoofer, trackpad-subwoofer, taptic-engine, force-touch,
desksetup, macsetups, aesthetic, lofi, satisfying, eye-candy,
glassmorphism, audiophile, lossless, coreaudio,
lyrics, karaoke, spotify, apple-music, macos-menubar, macapps, swiftui, reverse-engineering
```

---

## Installation & macOS Permissions

### Download DMG
1. Download **`LyricsMenuBar-1.2.0.dmg`** from [Releases](https://github.com/tum212/Lyrics-Menu-Bar/releases).
2. Drag **Lyrics Menu Bar** into your `/Applications` directory.
3. Grant **Automation** permissions for Music / Spotify when prompted.

> [!TIP]
> **macOS Gatekeeper First Launch:**  
> Right-click the app in `/Applications` and select **Open**, or execute in Terminal:  
> ```bash
> xattr -cr "/Applications/Lyrics Menu Bar.app"
> ```

---

## Building from Source

```bash
# Clone the repository
git clone https://github.com/tum212/Lyrics-Menu-Bar.git
cd Lyrics-Menu-Bar

# Compile production binary via Swift Package Manager
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

# Assemble and code-sign release DMG
bash build_dmg.sh sonoma
```

---

## Repository Architecture

```
LyricsMenuBar/
├── Package.swift                    # Swift Package Manager manifest (macOS 14.2+)
├── build_dmg.sh                     # Automated DMG builder & code-signing script
├── LyricsMenuBar.entitlements       # Hardened runtime & CoreAudio tap entitlements
├── icon.icns                        # macOS icon bundle
├── MyIcon.iconset/                  # Raw icon master assets
├── docs/images/                     # High-resolution documentation assets
│   ├── app_icon.png                 # Browser-compatible PNG application icon
│   ├── benchmark_hero.png           # Full Retina desktop hero screenshot ("No Better")
│   ├── lyrics_window_singing.gif    # High-resolution animated word glow
│   ├── lyrics_window_singing.png    # Popover window active word glow detail
│   ├── menubar_interlude_stars.gif  # High-resolution animated melody interlude stars
│   ├── menubar_lyrics_and_waveform.gif # High-resolution animated dynamic island waveform
│   └── menubar_lyrics_and_waveform.png # Menu Bar real-time lyrics & equalizer
├── Sources/
│   └── LyricsMenuBar/
│       ├── LyricsMenuBarApp.swift   # NSStatusItem & CoreGraphics marquee engine
│       ├── ContentView.swift        # Glass HUD window, WordLyricItemView & popover
│       ├── HUDGlassView.swift       # Hardware-accelerated GPU glass backdrop
│       ├── LyricsService.swift      # Multi-server lyrics client & phonetics engine
│       ├── MusicService.swift       # Dual Apple Music + Spotify IPC controller
│       ├── AudioAnalyzer.swift      # CoreAudio tap & vDSP FFT spectrum analyzer
│       ├── HapticManager.swift      # Low-latency Force Touch trackpad driver
│       ├── ColorExtractor.swift     # HSV vibrant quantization color pipeline
│       ├── LaunchAtLoginManager.swift # SMAppService modern login item manager
│       └── SpotifyService.swift     # Backward compatibility typealias bridge
└── README.md                        # Documentation
```

---

## 📄 License
Licensed under the **MIT License**.

<p align="center">
  Crafted with care for macOS music lovers everywhere. 🎶
</p>
