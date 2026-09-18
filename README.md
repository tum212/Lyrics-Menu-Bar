# 🎵 Lyrics Menu Bar (macOS)

<p align="center">
  <img src="icon.icns" width="128" height="128" alt="Lyrics Menu Bar Icon">
</p>

<p align="center">
  <b>The ultimate real-time lyrics & audio companion for macOS menu bar.</b><br>
  Engineered with Apple Music precision, fluid liquid glass physics, and ultra-low CPU footprint.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2013.0%2B-blue?style=flat-square&logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.10-orange?style=flat-square&logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/Release-v1.2.0-emerald?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon%20%2F%20Intel-purple?style=flat-square" alt="Arch">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
</p>

---

## ✨ Overview

**Lyrics Menu Bar** is an ultra-polished, native macOS utility that brings dynamic, word-by-word synced lyrics, an interactive liquid glass lyrics window, and an authentic Apple-style audio spectrum visualizer directly to your macOS Menu Bar.

Designed to feel like an official macOS system component, it integrates seamlessly with both **Apple Music** and **Spotify**, delivering buttery-smooth 60 FPS typography and continuous luminescent transitions.

---

## 🌟 Key Features

### 1. 🎤 Apple-Grade Word-by-Word Synchronized Lyrics
- **Continuous Cosine Glow Decay ($C^1$ Continuity):** Replicates Apple Music's physical phosphorescence. Sung words smoothly decay their glowing bloom over 320ms rather than cutting off abruptly ("หลอดไฟดับวาบ"), ensuring a seamless luminescent torch-pass between consecutive words.
- **Phonetic & Syllabic Timing Algorithms:** Uses English phoneme syllable estimation, word stress weighting, and pre-pausal lengthening (1.75× vocal sustain for line-ending syllables) for mathematically accurate word sweeps when only line timestamps exist.
- **Feathered Leading Spotlight:** A soft 16–24px gradient wipe front sweeps across active words without jerky discrete step functions.
- **Soft Line Crossfade:** When singing moves to the next line, the outgoing line gently dissolves its white luminescence over 380ms into resting past text opacity (32%), eliminating visual jarring.
- **Zero-Unmount SwiftUI Architecture:** The lyrics view hierarchy maintains a constant node graph with zero node insertion/destruction at 60 FPS, completely preventing micro-stutters and frame drops.

### 2. 📊 Authentic Apple Waveform Equalizer
- **Native Audio Spectrum Physics:** Inspired by Apple Music's live equalizer. Responsive frequency-band analysis with realistic bass, mid, and treble dynamics.
- **Bass Ceiling Impacts & Elastic Rebound:** Deep low-frequency peaks realistically hit the ceiling clamp with a spring-like velocity rebound.
- **Album Art Adaptive Color Blending:** Samples dominant vibrant pigments directly from the current song's cover art, blending into a translucent liquid glass glow that naturally complements the active track.

### 3. 🖱️ Click-to-Seek Interactive Lyrics
- Click on any lyric line (past or upcoming) to immediately seek playback in Apple Music or Spotify to that exact timestamp.
- Subtle Force Touch haptic confirmation on seek.

### 4. 🎛️ Real-Time Menu Bar Spotlight & Hermite Marquee
- **Real-Time Word Spotlight in Menu Bar:** The current lyric line is displayed directly in your macOS menu bar with real-time text highlighting synchronized to playback.
- **$C^1$ Smooth Hermite Marquee:** For lyrics that exceed the menu bar width, an ultra-smooth cubic Hermite curve ($S(x) = 3x^2 - 2x^3$) glides the text horizontally with natural rest periods at the start and end.
- **Melody Interlude Sparkles (✦):** When an instrumental break or guitar solo occurs, the menu bar smoothly transitions into an ethereal three-star pulsing constellation animation.

### 5. 🪟 Liquid Glass Popover Window
- Premium macOS Sonoma/Sequoia style translucent glass backdrop (`NSVisualEffectView` + vibrant blending).
- Cover art thumbnail with high-resolution caching.
- Native AppKit context menu for settings (zero flickering).
- **Launch at Login:** Fully integrated via modern macOS `SMAppService`.
- **Force Touch Haptic Feedback:** Multi-level haptic pulsing options for compatible trackpads.

---

## 📐 The Mathematics & Physics Behind the Lyrics

### 1. Continuous Glow Decay Model
In digital typography, binary thresholding (`if currentTime >= word.endTime`) causes an instantaneous step function in luminance, making lightbulbs appear to snap off. Lyrics Menu Bar solves this using a $C^0$ and $C^1$ continuous cosine easing decay function:

$$\text{decayFactor}(t) = \frac{1 + \cos\left(\min\left(1, \frac{t - t_{\text{end}}}{\tau}\right) \cdot \pi\right)}{2}$$

Where:
- $\tau = 0.32\,\text{s}$ (320ms decay window)
- $\text{GlowOpacity}(t) = 0.35 + 0.40 \cdot \text{decayFactor}(t)$
- $\text{GlowRadius}(t) = 2.8 + 2.7 \cdot \text{decayFactor}(t)$

Because $\frac{d}{dt}\cos(t)\Big|_{t=0} = -\sin(0) = 0$, the derivative at the moment the word finishes is zero, preventing any visual velocity kink and creating an analog phosphorescent afterglow.

### 2. Syllable & Phoneme Weight Distribution
When word-level timings are not explicitly provided by the lyrics provider, timestamps are computed dynamically:

$$\text{Weight}(w) = \left(0.70 \cdot S(w) + 0.08 \cdot C(w) + 0.22\right) \cdot M_{\text{stress}} \cdot M_{\text{punct}} \cdot M_{\text{terminal}}$$

- $S(w)$: Syllable count derived from phonetic vowel clustering.
- $C(w)$: Character length.
- $M_{\text{stress}}$: $0.65$ for unstressed function words (*a, the, in, to, and, but, is*).
- $M_{\text{punct}}$: $1.25$ to $1.30$ for commas, dashes, question marks.
- $M_{\text{terminal}}$: $1.75$ for the last word of a line to account for pre-pausal lengthening and vocal sustain.

---

## 🚀 Installation

### Option 1: Download DMG (Recommended)
1. Download the latest **`LyricsMenuBar-1.2.0.dmg`** from the [Releases](https://github.com/tum212/Lyrics-Menu-Bar/releases) page.
2. Open the DMG and drag **Lyrics Menu Bar** to your **Applications** folder.
3. Launch **Lyrics Menu Bar** from `/Applications` or Spotlight.

> [!TIP]
> **macOS Gatekeeper Notice:**  
> Since the application is self-signed, macOS may show a developer security prompt on the first launch.  
> Right-click the app in `/Applications` and select **Open**, or run in Terminal:  
> ```bash
> xattr -cr "/Applications/Lyrics Menu Bar.app"
> ```

---

## 🛠️ Permissions Setup

To enable complete synchronization, macOS will request access to:
1. **Automation / ScriptingBridge:**
   - Go to **System Settings > Privacy & Security > Automation**.
   - Ensure **Lyrics Menu Bar** has permission to control **Music** and/or **Spotify**.
2. **Launch at Login (Optional):**
   - Click the ellipsis (`...`) in the top right of the lyrics window and toggle **Launch at Login**.

---

## 💻 Building from Source

### Prerequisites
- macOS 13.0 (Ventura) or newer.
- Xcode 15+ or Xcode Command Line Tools.
- Swift 5.10+.

### Clone & Build
```bash
# Clone the repository
git clone https://github.com/tum212/Lyrics-Menu-Bar.git
cd Lyrics-Menu-Bar

# Build release binary via Swift Package Manager
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

# Package into a release DMG with background art and entitlements
bash build_dmg.sh sonoma
```

The resulting release bundle and DMG will be generated at:
- `Lyrics Menu Bar.app`
- `LyricsMenuBar-1.2.0.dmg`

---

## 📂 Project Architecture

```
LyricsMenuBar/
├── Package.swift                    # Swift Package Manager manifest
├── build_dmg.sh                     # Automated DMG builder & code signer
├── LyricsMenuBar.entitlements       # Hardened runtime & audio tap entitlements
├── icon.icns                        # High-resolution macOS app icon
├── Sources/
│   └── LyricsMenuBar/
│       ├── LyricsMenuBarApp.swift   # App entry point, NSStatusItem & menu bar renderer
│       ├── ContentView.swift        # Main UI, Apple Music lyrics window, Popover controller
│       ├── LyricsService.swift      # Multi-source lyrics fetching, LRU cache & phonetic timing math
│       ├── SpotifyController.swift  # Dual ScriptingBridge engine (Apple Music + Spotify)
│       ├── AudioAnalyzer.swift      # Real-time CoreAudio spectrum tap & FFT analysis
│       └── HapticManager.swift      # Trackpad Force Touch haptic engine
└── README.md                        # Documentation
```

### Component Breakdown
- **`ContentView.swift`:** Renders the expandable popover window using SwiftUI and AppKit. Hosts `WordLyricItemView`, `LyricLineRowView`, dynamic album art blur, and click-to-seek routing.
- **`LyricsMenuBarApp.swift`:** Manages the `NSStatusItem` in the macOS menu bar, handles CoreGraphics subpixel font rendering, interlude star particle effects, and continuous Hermite marquee scrolling.
- **`LyricsService.swift`:** Fetches synced lyrics via multiple low-latency backends (LRCLIB, NetEase, Musixmatch format), with in-memory caching and `LyricTimingCalculator` for syllable weighting.
- **`SpotifyController.swift`:** Actively tracks playback state, track ID, artist, title, artwork, and monotonic sub-second elapsed time across Spotify and Apple Music.
- **`AudioAnalyzer.swift`:** Taps system audio output with CoreAudio to perform fast frequency decomposition for the waveform visualizer.

---

## ⚙️ Settings & Customization

Click the **`...`** button in the top-right corner of the lyrics window to customize:
- **Waveform Equalizer Bars:** Choose between 8, 14, 20 bars, or set a custom bar count (up to 128 bars).
- **Menu Bar Lyrics Width:** Adjust maximum pixel width allocated in your menu bar (120px to 380px).
- **Music Source Mode:** Auto, Spotify Preferred, or Apple Music Preferred.
- **Haptic Intensity:** Off, Subtle, Medium, or Strong trackpad Force Touch feedback.
- **Launch at Login:** Enable or disable automatic launch on macOS boot.

---

## 📄 License

This project is licensed under the **MIT License**. Feel free to use, modify, and distribute with attribution.

---

<p align="center">
  Crafted with care for macOS music lovers. 🎶
</p>
