import SwiftUI
import AppKit
import Combine
import CoreAudio
import AVFoundation
import AudioToolbox
import Cocoa
import CoreVideo
import os

@main
struct SpoticatApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

let appLogger = Logger(subsystem: "com.lyricsmenubar.app", category: "General")

func logDebug(_ msg: String) {
    #if DEBUG
    appLogger.debug("\(msg, privacy: .public)")
    #endif
}

final class AtomicBool: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value: Bool = false
    
    func testAndSet() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if value { return false }
        value = true
        return true
    }
    
    func reset() {
        os_unfair_lock_lock(&lock)
        value = false
        os_unfair_lock_unlock(&lock)
    }
}

struct LyricsRenderKey: Equatable {
    let text: String
    let canvasWidth: CGFloat
    let isDark: Bool
    let marqueeOffsetQuantized: Int
    let wordLeadXQuantized: Int
    let transitionProgressQuantized: Int
    let isSparkling: Bool
    let sparkleFrame: Int
    let isInterlude: Bool
    let interludeFrame: Int
}

struct MenuBarRenderKey: Equatable {
    let trackId: String
    let isPlaying: Bool
    let isDark: Bool
    let showLyrics: Bool
    let showAlbumArt: Bool
    let waveformBars: Int
    let text: String
    let artRevision: Int
    let quantizedWidth: CGFloat
    let lyricsX: CGFloat
    let lyricsWidth: CGFloat
    let marqueeOffsetQuantized: Int
    let wordLeadXQuantized: Int
    let transitionProgressQuantized: Int
    let isSparkling: Bool
    let sparkleFrame: Int
    let isInterlude: Bool
    let interludeFrame: Int
    let vizWidth: CGFloat
    let barHeightsQuantized: [Int]
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    
    // Core Services
    var spotify = SpotifyService()
    var lyricsService = LyricsService()
    var audioAnalyzer = AudioAnalyzer()
    
    // Menu Bar State
    var statusItem: NSStatusItem!
    var updateTimer: Timer?
    var displayLink: CVDisplayLink?
    private let isFramePending = AtomicBool()
    private var lastMenuBarRenderKey: MenuBarRenderKey?
    private var lastLyricsRenderKey: LyricsRenderKey?
    private var cachedLyricsImage: NSImage?
    private var isShowingIdleIcon: Bool = false
    private var cachedAlbumArtTrackId: String?
    private var cachedAlbumArtImage: NSImage?
    
    private var lastShowWaveform = true
    private var lastShowAlbumArt = true
    private var lastShowLyrics = true
    var cancellables = Set<AnyCancellable>()
    // Lyrics Animation State
    var lastLyricsId: UUID?
    var animatedWidth: CGFloat = 20.0
    // Optimization: skip redraw when content hasn't changed
    var lastRenderedLyricsText: String = ""
    var currentCachedGrayText: NSImage?
    var currentCachedWhiteText: NSImage?
    var oldCachedGrayText: NSImage?
    var oldCachedWhiteText: NSImage?
    var lastRenderedHighlightedImage: NSImage?
    var lastWordLeadX: CGFloat?
    var lastRenderedProgress: Double = -1
    var forceRedrawLyrics: Bool = false
    var animatedOrbAlpha: CGFloat = 0.0
    
    // Marquee & Transition State
    var marqueeOffset: CGFloat = 0.0
    var oldMarqueeOffset: CGFloat = 0.0
    var oldLineText: String = ""
    var transitionProgress: CGFloat = 1.0
    var lastFrameTime: Date = Date()
    
    // Waveform Animation & Color State
    var lastAmplitudes: [Double] = []
    var barHeights: [CGFloat] = []
    var cachedWaveformTheme: WaveformTheme = .fallback
    
    // Sparkle Animation State
    var trackChangedTime: Date = Date.distantPast
    var lastTrackIdForSparkle: String = ""
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        AppDefaults.register()
        
        let contentView = ContentView(
            musicService: spotify,
            lyricsService: lyricsService,
            audioAnalyzer: audioAnalyzer
        )
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating

        // 2. Setup Native Liquid Glass Material Layer (AppKit GPU Compositing)
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 20
        visualEffect.layer?.masksToBounds = true

        // 3. Setup HostingView & Pin to VisualEffectView
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])

        panel.contentView = visualEffect
        panel.delegate = self
        self.panel = panel
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleClosePopover), name: Notification.Name("ClosePopover"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleDistributedTogglePopover), name: NSNotification.Name("com.spoticat.TogglePopover"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioFeaturesDisabled), name: Notification.Name("AudioFeaturesDisabled"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioFeaturesEnabled), name: Notification.Name("AudioFeaturesEnabled"), object: nil)
        
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = self.statusItem.button {
            let img = NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: "Lyrics Menu Bar")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        // Auto-fetch lyrics when track changes, because ContentView might not be visible yet
        spotify.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self = self else { return }
                if let track = track {
                    self.lyricsService.fetchLyrics(trackName: track.name, artistName: track.artist, albumName: track.album)
                } else {
                    self.lyricsService.lyrics = []
                    self.audioAnalyzer.stop()
                }
            }
            .store(in: &cancellables)
            
        spotify.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                let waveformBars = UserDefaults.standard.integer(forKey: "waveformBars")
                let featuresEnabled = UserDefaults.standard.bool(forKey: "audioFeaturesEnabled")
                if isPlaying && waveformBars > 0 && featuresEnabled {
                    self.audioAnalyzer.start()
                } else {
                    self.audioAnalyzer.stop()
                }
            }
            .store(in: &cancellables)
        
        // Start live updating the Menu Bar at 60fps / CVDisplayLink
        startMenuBarUpdater()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePopover(nil)
        return true
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        guard let panel = self.panel else { return }
        if panel.isVisible {
            spotify.isPanelVisible = false
            panel.orderOut(nil)
        } else {
            let screen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let panelWidth: CGFloat = 480
            let panelHeight: CGFloat = 240
            
            var xPos: CGFloat
            var yPos: CGFloat
            
            if let button = statusItem?.button, let buttonWindow = button.window, buttonWindow.frame.origin.y > 0 {
                let buttonRect = buttonWindow.convertToScreen(button.frame)
                xPos = buttonRect.midX - (panelWidth / 2)
                yPos = buttonRect.minY - panelHeight - 8
            } else {
                xPos = screenFrame.maxX - panelWidth - 20
                yPos = screenFrame.maxY - panelHeight - 8
            }
            
            // Clamp within screen boundaries
            xPos = max(screenFrame.minX + 10, min(xPos, screenFrame.maxX - panelWidth - 10))
            yPos = max(screenFrame.minY + 10, min(yPos, screenFrame.maxY - panelHeight - 8))
            
            panel.setFrame(NSRect(x: xPos, y: yPos, width: panelWidth, height: panelHeight), display: true)
            panel.invalidateShadow()
            spotify.isPanelVisible = true
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopMenuBarUpdater()
        audioAnalyzer.stop()
        HapticManager.shared.teardown()
        spotify.cleanup()
    }
    
    @objc private func handleClosePopover() {
        spotify.isPanelVisible = false
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == panel {
            spotify.isPanelVisible = false
            panel?.orderOut(nil)
        }
    }

    @objc private func handleDistributedTogglePopover() {
        togglePopover(nil)
    }

    @objc private func handleAudioFeaturesDisabled() {
        audioAnalyzer.stop()
    }

    @objc private func handleAudioFeaturesEnabled() {
        if spotify.isPlaying {
            audioAnalyzer.start()
        }
    }
    
    func startMenuBarUpdater() {
        stopMenuBarUpdater()
        
        // 30 FPS menu bar timer on .common RunLoop
        // Eliminates WindowServer 40% CPU usage and Mach IPC bitmap serialization flood
        let timer = Timer.scheduledTimer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(timerTick), userInfo: nil, repeats: true)
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }
    
    func stopMenuBarUpdater() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            self.displayLink = nil
        }
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    @objc private func timerTick() {
        updateMenuBar()
    }

    private func getNotchSafeMaxWidth() -> CGFloat {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        if #available(macOS 12.0, *), let rightArea = screen?.auxiliaryTopRightArea {
            let maxSafeWidth = max(120.0, rightArea.width - 260.0)
            return maxSafeWidth
        }
        return 600.0
    }
    
    func roundCorners(of image: NSImage, size: NSSize, radius: CGFloat) -> NSImage {
        let roundedImage = NSImage(size: size)
        roundedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius)
        path.addClip()
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        roundedImage.unlockFocus()
        return roundedImage
    }
    
    
    
    func updateMenuBar() {
        let now = Date()
        if Int(now.timeIntervalSince1970 * 10) % 20 == 0 {
            logDebug("updateMenuBar: track=\(spotify.currentTrack?.name ?? "nil"), statusWinFrame=\(statusItem?.button?.window?.frame as Any), isVis=\(statusItem?.isVisible ?? false)")
        }
        var deltaTime = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now
        if deltaTime > 0.1 || deltaTime <= 0 { deltaTime = 0.016 }
        
        var waveformBars = 14
        if UserDefaults.standard.object(forKey: "waveformBars") != nil {
            waveformBars = min(128, max(0, UserDefaults.standard.integer(forKey: "waveformBars")))
        }
        let showAlbumArt = UserDefaults.standard.bool(forKey: "showAlbumArt")
        let showLyrics = UserDefaults.standard.bool(forKey: "showLyrics")
        
        // Pass dynamic band count to audio analyzer
        if waveformBars > 0 {
            audioAnalyzer.updateBandCount(waveformBars)
        }
        
        // Check for state changes to force redraw
        let prefsChanged = (waveformBars != UserDefaults.standard.integer(forKey: "lastWaveformBars") || showAlbumArt != lastShowAlbumArt || showLyrics != lastShowLyrics)
        if prefsChanged {
            UserDefaults.standard.set(waveformBars, forKey: "lastWaveformBars")
            lastShowAlbumArt = showAlbumArt
            lastShowLyrics = showLyrics
        }
        
        let isVisible = showLyrics || (waveformBars > 0) || showAlbumArt || (spotify.currentTrack == nil)
        if statusItem?.isVisible != isVisible {
            statusItem?.isVisible = isVisible
        }
        
        if let track = spotify.currentTrack {
            isShowingIdleIcon = false
            guard let button = self.statusItem?.button else { return }
            let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let primaryTextColor = isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)
            
            let sparkleTime = now.timeIntervalSince(trackChangedTime)
            let isSparkling = lyricsService.isLoading || sparkleTime < 5.5
            
            if lastTrackIdForSparkle != track.id {
                lastTrackIdForSparkle = track.id
                trackChangedTime = now
            }
            
            // --- 1. LYRICS UPDATING (Left Item) ---
            let time = spotify.currentTime
            let allLyrics = lyricsService.lyrics
            var currentLineText = ""
            var isUnsynced = false
            var currentIndex = 0
            var peekedAhead = false
            var isIntro = false
            
            if !allLyrics.isEmpty {
                isUnsynced = allLyrics.count > 1 && allLyrics.last!.time == 0
                if isUnsynced {
                    let duration = track.duration > 0 ? track.duration : 100.0
                    let progress = max(0, min(1, time / duration))
                    currentIndex = Int(progress * Double(allLyrics.count))
                    if currentIndex >= allLyrics.count { currentIndex = allLyrics.count - 1 }
                    currentLineText = allLyrics[currentIndex].text
                } else if let firstTime = allLyrics.first?.time, firstTime > 0 && time < firstTime {
                    isIntro = true
                    let sparkleTime = now.timeIntervalSince(trackChangedTime)
                    if sparkleTime < 5.5 {
                        currentLineText = track.name
                    } else {
                        currentLineText = "♪ \(track.name) - \(track.artist)"
                    }
                } else {
                    for (index, line) in allLyrics.enumerated() {
                        if line.time <= time { currentIndex = index } else { break }
                    }
                    let activeLine = allLyrics[currentIndex]
                    currentLineText = activeLine.text
                    
                    if currentLineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if currentIndex + 1 < allLyrics.count {
                            let nextText = allLyrics[currentIndex + 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !nextText.isEmpty { 
                                currentLineText = nextText 
                                peekedAhead = true
                            } else { 
                                currentLineText = "♪" 
                            }
                        } else { currentLineText = "♪" }
                    }
                }
            } else {
                if lyricsService.isLoading {
                    currentLineText = track.name
                } else {
                    let totalSparkleDuration = 5.5
                    let sparkleTime = now.timeIntervalSince(trackChangedTime)
                    if sparkleTime < totalSparkleDuration {
                        currentLineText = track.name
                    } else {
                        currentLineText = "\(track.name) - \(track.artist) • \(track.album)"
                    }
                }
            }
            
            if currentLineText.isEmpty { currentLineText = "♪" }
            if currentLineText.count > 75 { currentLineText = String(currentLineText.prefix(72)) + "..." }
            
            lastLyricsId = (allLyrics.isEmpty || isIntro) ? nil : allLyrics[currentIndex].id
            
            let font = NSFont.systemFont(ofSize: 14, weight: .regular)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            paragraphStyle.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle]
            let textSize = currentLineText.size(withAttributes: attributes)
            
            var progress = 0.0
            var wordLeadX: CGFloat? = nil
            let fadeWidth: CGFloat = 24.0
            
            if isIntro {
                progress = 0.0
            } else if !allLyrics.isEmpty && currentIndex < allLyrics.count {
                let activeLine = allLyrics[currentIndex]
                if peekedAhead {
                    progress = 0.0
                } else if isUnsynced {
                    // Unsynced lyrics: always display line 100% lit up with no frozen spotlight
                    progress = 1.0
                    wordLeadX = textSize.width + fadeWidth
                } else {
                    let activeWords = activeLine.words
                    
                    if !activeWords.isEmpty && activeLine.endTime > activeLine.time {
                        let vocalStart = activeWords.first?.startTime ?? activeLine.time
                        let vocalEnd = activeWords.last?.endTime ?? activeLine.endTime
                        let vocalDuration = max(0.01, vocalEnd - vocalStart)
                        if time < vocalStart {
                            progress = 0.0
                            wordLeadX = -fadeWidth
                        } else if time >= vocalEnd {
                            progress = 1.0
                            wordLeadX = textSize.width + fadeWidth
                        } else {
                            progress = max(0.0, min(1.0, (time - vocalStart) / vocalDuration))
                            var foundWord = false
                            var searchStart = currentLineText.startIndex
                            
                            for word in activeWords {
                                let targetRange: Range<String.Index>?
                                if let r = currentLineText.range(of: word.text, range: searchStart..<currentLineText.endIndex) {
                                    targetRange = r
                                    searchStart = r.upperBound
                                } else if let r = currentLineText.range(of: word.text) {
                                    targetRange = r
                                } else {
                                    targetRange = nil
                                }
                                
                                if time >= word.startTime && time < word.endTime {
                                    if let r = targetRange {
                                        let prefix = String(currentLineText[..<r.lowerBound])
                                        let prefixW = prefix.size(withAttributes: attributes).width
                                        let wordW = word.text.size(withAttributes: attributes).width
                                        let wordDur = max(0.01, word.endTime - word.startTime)
                                        let wp = CGFloat((time - word.startTime) / wordDur)
                                        wordLeadX = prefixW + wordW * wp
                                        foundWord = true
                                    }
                                    break
                                } else if time < word.startTime {
                                    if let r = targetRange {
                                        let prefix = String(currentLineText[..<r.lowerBound])
                                        wordLeadX = prefix.size(withAttributes: attributes).width
                                        foundWord = true
                                    }
                                    break
                                }
                            }
                            if !foundWord {
                                wordLeadX = textSize.width * CGFloat(progress)
                            }
                            
                            // Monotonic forward clamp within the same line to prevent subpixel jitter
                            if let lastX = self.lastWordLeadX, let newX = wordLeadX, currentLineText == lastRenderedLyricsText {
                                wordLeadX = max(lastX, newX)
                            }
                            self.lastWordLeadX = wordLeadX
                        }
                    } else if currentIndex < allLyrics.count - 1 {
                        let currentStart = allLyrics[currentIndex].time
                        let nextStart = allLyrics[currentIndex + 1].time
                        let rawDuration = max(0.1, nextStart - currentStart)
                        let activeDuration = min(rawDuration, 8.0)
                        progress = max(0, min(1, (time - currentStart) / activeDuration))
                    } else {
                        progress = 1.0
                    }
                }
            }
            
            let glowPad: CGFloat = 6
            
            var lyricsMaxWidth = 200
            if UserDefaults.standard.object(forKey: "lyricsMaxWidth") != nil {
                lyricsMaxWidth = UserDefaults.standard.integer(forKey: "lyricsMaxWidth")
            }
            let maxW = CGFloat(lyricsMaxWidth)
            let safeCap = getNotchSafeMaxWidth()
            let effectiveMaxW = min(maxW, safeCap)
            let neededW = ceil(textSize.width) + 32.0
            let canvasWidth: CGFloat = min(effectiveMaxW, max(60.0, neededW))
            
            let scrollPadding: CGFloat = 16.0
            let fullTextWidth = textSize.width + glowPad * 2
            let effectiveWidth = canvasWidth - scrollPadding * 2
            let isMarquee = canvasWidth > 0 && fullTextWidth > effectiveWidth && currentLineText != "♪"
            
            var targetOffset: CGFloat = scrollPadding
            if isMarquee {
                let maxScroll = fullTextWidth - effectiveWidth
                if isUnsynced {
                    // Unsynced lyrics: continuous smooth reading scroll at 38 px/s with gentle pause at start/end
                    let scrollSpeed: CGFloat = 38.0
                    let travelTime = Double(maxScroll / scrollSpeed)
                    let pauseTime = 1.6
                    let fullCycle = travelTime + pauseTime * 2
                    let cycleT = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: fullCycle)
                    if cycleT < pauseTime {
                        targetOffset = scrollPadding
                    } else if cycleT < pauseTime + travelTime {
                        let tFrac = CGFloat((cycleT - pauseTime) / travelTime)
                        targetOffset = scrollPadding - (maxScroll * tFrac)
                    } else {
                        targetOffset = scrollPadding - maxScroll
                    }
                } else {
                    // Continuous C^1 smooth Hermite motion across the line:
                    // Using smoothstep Hermite curve: S(x) = 3x^2 - 2x^3
                    // Starts smoothly at 0 velocity, glides without jerky word-gap snaps, rests at end
                    let smoothT = CGFloat(progress * progress * (3.0 - 2.0 * progress))
                    targetOffset = scrollPadding - (maxScroll * smoothT)
                }
            }
            
            if currentLineText != lastRenderedLyricsText {
                oldLineText = lastRenderedLyricsText
                oldCachedGrayText = currentCachedGrayText
                oldCachedWhiteText = lastRenderedHighlightedImage ?? currentCachedWhiteText
                lastRenderedHighlightedImage = nil
                lastWordLeadX = nil
                oldMarqueeOffset = marqueeOffset
                lastRenderedLyricsText = currentLineText
                transitionProgress = 0.0
                
                let safeSize = NSSize(width: ceil(textSize.width) + 4, height: 20)
                if safeSize.width > 4 {
                    let textRect = NSRect(x: 0, y: (20 - textSize.height) / 2.0, width: textSize.width, height: textSize.height)
                    
                    let newGrayImg = NSImage(size: safeSize)
                    newGrayImg.lockFocus()
                    if let ctx = NSGraphicsContext.current?.cgContext {
                        ctx.setAllowsFontSubpixelPositioning(true)
                        ctx.setShouldSubpixelPositionFonts(true)
                        ctx.setAllowsFontSubpixelQuantization(true)
                        ctx.setShouldSubpixelQuantizeFonts(false)
                    }
                    var attr = attributes
                    attr[.foregroundColor] = isDark ? NSColor.white.withAlphaComponent(1.0) : NSColor(white: 0.1, alpha: 1.0)
                    currentLineText.draw(at: textRect.origin, withAttributes: attr)
                    newGrayImg.unlockFocus()
                    currentCachedGrayText = newGrayImg
                    
                    let newWhiteImg = NSImage(size: safeSize)
                    newWhiteImg.lockFocus()
                    if let ctx = NSGraphicsContext.current?.cgContext {
                        ctx.setAllowsFontSubpixelPositioning(true)
                        ctx.setShouldSubpixelPositionFonts(true)
                        ctx.setAllowsFontSubpixelQuantization(true)
                        ctx.setShouldSubpixelQuantizeFonts(false)
                    }
                    var attrW = attributes
                    attrW[.foregroundColor] = primaryTextColor
                    currentLineText.draw(at: textRect.origin, withAttributes: attrW)
                    newWhiteImg.unlockFocus()
                    currentCachedWhiteText = newWhiteImg
                } else {
                    currentCachedGrayText = nil
                    currentCachedWhiteText = nil
                }
                
                // Keep the newly arrived line resting comfortably at the starting scrollPadding
                marqueeOffset = scrollPadding
            } else {
                // When line is still settling in during vertical transition, don't jerk horizontally
                let effectiveTarget = transitionProgress < 0.45 ? scrollPadding : targetOffset
                let smoothSpeed = CGFloat(1.0 - exp(-16.0 * deltaTime))
                marqueeOffset += (effectiveTarget - marqueeOffset) * smoothSpeed
            }
            
            if transitionProgress < 1.0 {
                transitionProgress += CGFloat(deltaTime / 0.42)
                if transitionProgress > 1.0 { transitionProgress = 1.0 }
            }
            
            var lyricsImgToDraw: NSImage? = nil
            if showLyrics && canvasWidth > 2 {
                let isInterlude = currentLineText.contains("✦")
                let currentLyricsKey = LyricsRenderKey(
                    text: currentLineText,
                    canvasWidth: canvasWidth,
                    isDark: isDark,
                    marqueeOffsetQuantized: Int(marqueeOffset * 2.0),
                    wordLeadXQuantized: Int((wordLeadX ?? -100.0) * 2.0),
                    transitionProgressQuantized: Int(transitionProgress * 100.0),
                    isSparkling: isSparkling,
                    sparkleFrame: isSparkling ? Int(sparkleTime * 30.0) : 0,
                    isInterlude: isInterlude,
                    interludeFrame: isInterlude ? Int(now.timeIntervalSinceReferenceDate * 30.0) : 0
                )
                
                if currentLyricsKey == lastLyricsRenderKey, let cached = cachedLyricsImage {
                    lyricsImgToDraw = cached
                } else {
                    let trackName = track.name
                    let lyricsImage = NSImage(size: NSSize(width: canvasWidth, height: 20))
                    lyricsImage.lockFocus()
                    if let ctx = NSGraphicsContext.current?.cgContext {
                        ctx.setAllowsFontSubpixelPositioning(true)
                        ctx.setShouldSubpixelPositionFonts(true)
                        ctx.setAllowsFontSubpixelQuantization(true)
                        ctx.setShouldSubpixelQuantizeFonts(false)
                    }
                    NSGraphicsContext.current?.imageInterpolation = .high
                
                let t = transitionProgress
                let easedT = 1.0 - pow(1.0 - t, 3.0)
                
                let yOffsetOld = easedT * 14.0
                let alphaOld = max(0.0, 1.0 - easedT)
                
                let yOffsetNew = -14.0 + easedT * 14.0
                let alphaNew = easedT
                
                // 1. Draw old line sliding UP & crossfading out
                if transitionProgress < 1.0, let oldGray = oldCachedGrayText {
                    let oldPoint = NSPoint(x: glowPad + oldMarqueeOffset, y: yOffsetOld)
                    oldGray.draw(at: oldPoint, from: .zero, operation: .sourceOver, fraction: alphaOld * 0.4)
                }
                if transitionProgress < 1.0, let oldWhite = oldCachedWhiteText {
                    let oldPoint = NSPoint(x: glowPad + oldMarqueeOffset, y: yOffsetOld)
                    oldWhite.draw(at: oldPoint, from: .zero, operation: .sourceOver, fraction: alphaOld)
                }
                
                // 2. Draw new line sliding UP and fading in (or Melody Interlude Stars)
                let isInterlude = currentLineText.contains("✦")
                if isInterlude {
                    let starCount = 3
                    let spacing: CGFloat = 16.0
                    let startX = (canvasWidth - CGFloat(starCount - 1) * spacing) / 2.0
                    let centerY: CGFloat = 10.0 + yOffsetNew
                    let t = now.timeIntervalSinceReferenceDate * 3.8
                    
                    for sIdx in 0..<starCount {
                        let phase = Double(sIdx) * 0.8
                        let pulse = (sin(t + phase) + 1.0) * 0.5
                        let s = (3.0 + CGFloat(pulse) * 2.2) * alphaNew
                        let alpha = (0.50 + CGFloat(pulse) * 0.50) * alphaNew
                        let center = NSPoint(x: startX + CGFloat(sIdx) * spacing, y: centerY)
                        
                        NSGraphicsContext.current?.saveGraphicsState()
                        let shadow = NSShadow()
                        shadow.shadowColor = primaryTextColor.withAlphaComponent(alpha * 0.85)
                        shadow.shadowBlurRadius = 5.0
                        shadow.shadowOffset = .zero
                        shadow.set()
                        
                        let path = NSBezierPath()
                        path.move(to: NSPoint(x: center.x, y: center.y + s))
                        path.curve(to: NSPoint(x: center.x + s, y: center.y), controlPoint1: NSPoint(x: center.x, y: center.y + s * 0.3), controlPoint2: NSPoint(x: center.x + s * 0.3, y: center.y))
                        path.curve(to: NSPoint(x: center.x, y: center.y - s), controlPoint1: NSPoint(x: center.x + s * 0.3, y: center.y), controlPoint2: NSPoint(x: center.x + s * 0.3, y: center.y))
                        path.curve(to: NSPoint(x: center.x - s, y: center.y), controlPoint1: NSPoint(x: center.x - s * 0.3, y: center.y), controlPoint2: NSPoint(x: center.x - s * 0.3, y: center.y))
                        path.curve(to: NSPoint(x: center.x, y: center.y + s), controlPoint1: NSPoint(x: center.x - s * 0.3, y: center.y), controlPoint2: NSPoint(x: center.x, y: center.y + s * 0.3))
                        
                        primaryTextColor.withAlphaComponent(alpha).setFill()
                        path.fill()
                        NSGraphicsContext.current?.restoreGraphicsState()
                    }
                } else {
                    if let currentGray = currentCachedGrayText {
                        let newPoint = NSPoint(x: glowPad + marqueeOffset, y: yOffsetNew)
                        currentGray.draw(at: newPoint, from: .zero, operation: .sourceOver, fraction: alphaNew * 0.4)
                    }
                    
                    // Target alpha based on progress
                    let targetOrbAlpha: CGFloat = (progress > 0.0 && progress < 1.0) ? 1.0 : 0.0
                    let alphaSmoothing = CGFloat(1.0 - exp(-15.0 * deltaTime))
                    animatedOrbAlpha += (targetOrbAlpha - animatedOrbAlpha) * alphaSmoothing
                    
                    if (progress > 0 || animatedOrbAlpha > 0.01), let currentWhite = currentCachedWhiteText {
                        let safeSize = currentWhite.size
                        let fadeWidth: CGFloat = 24.0
                        let leadX: CGFloat
                        if let exactX = wordLeadX {
                            leadX = exactX
                        } else {
                            leadX = (safeSize.width + fadeWidth) * CGFloat(progress) - fadeWidth
                        }
                        let leadStart = max(0, leadX)
                        let leadEnd = min(safeSize.width, leadX + fadeWidth)
                        
                        let highlightedImg = NSImage(size: safeSize)
                        highlightedImg.lockFocus()
                        currentWhite.draw(at: .zero, from: NSRect(origin: .zero, size: safeSize), operation: .copy, fraction: 1.0)
                        
                        NSGraphicsContext.current?.compositingOperation = .destinationIn
                        if leadStart > 0 {
                            primaryTextColor.setFill()
                            NSRect(x: 0, y: 0, width: leadStart, height: safeSize.height).fill()
                        }
                        if leadEnd > leadStart, let grad = NSGradient(colors: [primaryTextColor, NSColor.clear]) {
                            grad.draw(from: NSPoint(x: leadStart, y: 0), to: NSPoint(x: leadEnd, y: 0), options: [])
                        }
                        if leadEnd < safeSize.width {
                            NSColor.clear.setFill()
                            NSRect(x: leadEnd, y: 0, width: safeSize.width - leadEnd, height: safeSize.height).fill()
                        }
                        highlightedImg.unlockFocus()
                        
                        let textPoint1 = NSPoint(x: glowPad + marqueeOffset, y: yOffsetNew)
                        highlightedImg.draw(at: textPoint1, from: .zero, operation: .sourceOver, fraction: alphaNew)
                        self.lastRenderedHighlightedImage = highlightedImg
                    }
                }
                let totalSparkleDuration = 5.5
                let isSparkling = lyricsService.isLoading || (sparkleTime < totalSparkleDuration && currentLineText == trackName)
                
                if isSparkling {
                    let cycleTime = lyricsService.isLoading ? sparkleTime.truncatingRemainder(dividingBy: totalSparkleDuration) : sparkleTime
                    let textW = textSize.width
                    
                    var seed = abs(currentLineText.hashValue)
                    func randomFloat() -> CGFloat {
                        seed = (seed &* 1664525) &+ 1013904223
                        return CGFloat(abs(seed) % 1000) / 1000.0
                    }
                    
                    for _ in 0..<18 {
                        let rx = randomFloat()
                        let ry = randomFloat()
                        let rt = randomFloat()
                        let rs = randomFloat()
                        let rd = randomFloat()
                        
                        let delay = Double(rt) * 4.5
                        let duration = 0.5 + Double(rd) * 0.7
                        let center = NSPoint(x: glowPad + marqueeOffset + textW * rx, y: 6.0 + 8.0 * ry)
                        let sizeMult = 0.7 + rs * 0.5
                        
                        let sp = max(0, min(1, (cycleTime - delay) / duration))
                        if sp > 0 && sp < 1 {
                            let s = sin(sp * .pi) * 5.0 * sizeMult
                            let alpha = sin(sp * .pi)
                            
                            NSGraphicsContext.current?.saveGraphicsState()
                            let shadow = NSShadow()
                            shadow.shadowColor = primaryTextColor.withAlphaComponent(alpha)
                            shadow.shadowBlurRadius = 4
                            shadow.shadowOffset = .zero
                            shadow.set()
                            
                            let path = NSBezierPath()
                            path.move(to: NSPoint(x: center.x, y: center.y + s))
                            path.curve(to: NSPoint(x: center.x + s, y: center.y), controlPoint1: NSPoint(x: center.x, y: center.y + s * 0.3), controlPoint2: NSPoint(x: center.x + s * 0.3, y: center.y))
                            path.curve(to: NSPoint(x: center.x, y: center.y - s), controlPoint1: NSPoint(x: center.x + s * 0.3, y: center.y), controlPoint2: NSPoint(x: center.x + s * 0.3, y: center.y))
                            path.curve(to: NSPoint(x: center.x - s, y: center.y), controlPoint1: NSPoint(x: center.x - s * 0.3, y: center.y), controlPoint2: NSPoint(x: center.x - s * 0.3, y: center.y))
                            path.curve(to: NSPoint(x: center.x, y: center.y + s), controlPoint1: NSPoint(x: center.x - s * 0.3, y: center.y), controlPoint2: NSPoint(x: center.x, y: center.y + s * 0.3))
                            
                            primaryTextColor.withAlphaComponent(alpha).setFill()
                            path.fill()
                            NSGraphicsContext.current?.restoreGraphicsState()
                        }
                    }
                }

                // Always apply Edge Masking for a premium fade at the boundaries
                if canvasWidth > 16 {
                    NSGraphicsContext.current?.saveGraphicsState()
                    NSGraphicsContext.current?.compositingOperation = .destinationIn
                    if let gradientLeft = NSGradient(colors: [.clear, .white]),
                       let gradientRight = NSGradient(colors: [.white, .clear]) {
                        gradientLeft.draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 16, y: 0), options: [])
                        gradientRight.draw(from: NSPoint(x: canvasWidth - 16, y: 0), to: NSPoint(x: canvasWidth, y: 0), options: [])
                        NSColor.white.setFill()
                        NSRect(x: 16, y: 0, width: canvasWidth - 32, height: 20).fill()
                    }
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
                
                lyricsImage.unlockFocus()
                cachedLyricsImage = lyricsImage
                lastLyricsRenderKey = currentLyricsKey
                lyricsImgToDraw = lyricsImage
                lastRenderedLyricsText = currentLineText
            }
        } else {
            cachedLyricsImage = nil
            lastLyricsRenderKey = nil
        }
        
        // --- 2. ART & WAVEFORM UPDATING ---
        let artKey = "\(track.id)_\(spotify.artworkRevision)"
        if cachedAlbumArtTrackId != artKey {
            cachedAlbumArtTrackId = artKey
            
            if let directImage = spotify.activeArtworkImage {
                let roundedImage = self.roundCorners(of: directImage, size: NSSize(width: 20, height: 20), radius: 4)
                let theme = ColorExtractor.extractWaveformTheme(from: directImage)
                self.cachedAlbumArtImage = roundedImage
                self.cachedWaveformTheme = theme
            } else {
                let fallback = NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: nil)
                fallback?.isTemplate = true
                self.cachedAlbumArtImage = fallback
                self.cachedWaveformTheme = .fallback
            }
        }
        
        var waveformBars = 14
        if UserDefaults.standard.object(forKey: "waveformBars") != nil {
            waveformBars = min(128, max(0, UserDefaults.standard.integer(forKey: "waveformBars")))
        }
        let barCount = waveformBars
        let barW: CGFloat = 2.0
        let barSp: CGFloat = 1.5
        let vizWidth: CGFloat = (barCount > 0 && spotify.isPlaying) ? CGFloat(barCount) * (barW + barSp) : 0
        let artWidth: CGFloat = (showAlbumArt && cachedAlbumArtImage != nil) ? 20.0 : 0
        let lyricsWidth: CGFloat = (showLyrics && lyricsImgToDraw != nil) ? canvasWidth : 0
        
        let gap: CGFloat = 8.0
        
        var totalWidth: CGFloat = 0
        var lyricsX: CGFloat = 0
        var vizX: CGFloat = 0
        var artX: CGFloat = 0
        
        if lyricsWidth > 0 {
            lyricsX = totalWidth
            totalWidth += lyricsWidth
        }
        if vizWidth > 0 {
            if totalWidth > 0 { totalWidth += gap }
            vizX = totalWidth
            totalWidth += vizWidth
        }
        if artWidth > 0 {
            if totalWidth > 0 { totalWidth += gap }
            artX = totalWidth
            totalWidth += artWidth
        }
        totalWidth = max(24.0, totalWidth)
        let quantizedWidth = ceil(totalWidth / 4.0) * 4.0
        
        // Calculate waveform physics & ballistics
        if vizWidth > 0 {
            let rawAmps = audioAnalyzer.amplitudes
            let count = barCount
            let hasLiveAudio = audioAnalyzer.isRunning && rawAmps.contains { $0 > 0.02 }
            
            // Initialize barHeights array if needed
            if barHeights.count != count {
                barHeights = Array(repeating: 2.5, count: count)
            }
            
            let minHeight: CGFloat = 2.5
            let maxHeight: CGFloat = 17.5 // True ceiling: punches up inside 20pt container with 1.25pt padding
            
            // Authentic physical bass energy from lower FFT bands (Bands 0-2: Sub-bass 60Hz-250Hz)
            var bassEnergy: CGFloat = 0.0
            if hasLiveAudio && rawAmps.count >= 3 {
                bassEnergy = (rawAmps[0] * 0.45 + rawAmps[1] * 0.35 + rawAmps[2] * 0.20)
            }
            
            // On loud bass transients (beat drops, 808 kicks), surge ALL bars to the ceiling simultaneously
            let bassSurge: CGFloat
            if bassEnergy > 0.58 {
                let surgeNorm = min(1.0, (bassEnergy - 0.58) / 0.28)
                bassSurge = pow(surgeNorm, 1.20)
            } else {
                bassSurge = 0.0
            }
            
            let timePhase = now.timeIntervalSince1970 * 4.0
            
            for i in 0..<count {
                let rawAmp: CGFloat
                if hasLiveAudio && !rawAmps.isEmpty {
                    let step = Double(rawAmps.count) / Double(count)
                    let srcIdx = min(rawAmps.count - 1, max(0, Int(Double(i) * step)))
                    rawAmp = CGFloat(rawAmps[srcIdx])
                } else {
                    rawAmp = 0.0
                }
                
                let energy: CGFloat
                if !spotify.isPlaying {
                    energy = 0.02
                } else if hasLiveAudio {
                    let bandAmp = pow(rawAmp, 0.85)
                    let combined = max(bandAmp, bassSurge * 0.98 + bandAmp * 0.20)
                    energy = min(1.0, max(0.04, combined))
                } else {
                    let barPhase = Double(i) * 0.55
                    let wave = (sin(timePhase * 1.2 + barPhase) * cos(timePhase * 0.5 + Double(i) * 0.25) + 1.0) * 0.5
                    energy = min(0.65, max(0.10, CGFloat(wave) * 0.40))
                }
                
                let targetH = minHeight + energy * (maxHeight - minHeight)
                let currentH = barHeights[i]
                
                let speed: CGFloat
                if targetH > currentH {
                    speed = CGFloat(1.0 - exp(-38.0 * deltaTime))
                } else {
                    speed = CGFloat(1.0 - exp(-14.0 * deltaTime))
                }
                
                let newH = currentH + (targetH - currentH) * speed
                barHeights[i] = newH
            }
        } else if !barHeights.isEmpty {
            barHeights.removeAll()
        }
        
        let isInterlude = currentLineText.contains("✦")
        let currentKey = MenuBarRenderKey(
            trackId: track.id,
            isPlaying: spotify.isPlaying,
            isDark: isDark,
            showLyrics: showLyrics,
            showAlbumArt: showAlbumArt,
            waveformBars: barCount,
            text: currentLineText,
            artRevision: spotify.artworkRevision,
            quantizedWidth: quantizedWidth,
            lyricsX: lyricsX,
            lyricsWidth: lyricsWidth,
            marqueeOffsetQuantized: Int(marqueeOffset * 2.0),
            wordLeadXQuantized: Int((wordLeadX ?? -100.0) * 2.0),
            transitionProgressQuantized: Int(transitionProgress * 100.0),
            isSparkling: isSparkling,
            sparkleFrame: isSparkling ? Int(sparkleTime * 30.0) : 0,
            isInterlude: isInterlude,
            interludeFrame: isInterlude ? Int(now.timeIntervalSinceReferenceDate * 30.0) : 0,
            vizWidth: vizWidth,
            barHeightsQuantized: barHeights.map { Int($0 * 2.0) }
        )

        if currentKey == lastMenuBarRenderKey && !prefsChanged && !forceRedrawLyrics {
            return
        }
        lastMenuBarRenderKey = currentKey
        forceRedrawLyrics = false
        
        let combinedImage = NSImage(size: NSSize(width: quantizedWidth, height: 20))
        combinedImage.lockFocus()
        
        // 1. Draw lyrics directly with NO black background capsule
        if let lyricsImg = lyricsImgToDraw {
            lyricsImg.draw(at: NSPoint(x: lyricsX, y: 0), from: NSRect(origin: .zero, size: lyricsImg.size), operation: .sourceOver, fraction: 1.0)
        }
        
        // 2. Draw Waveform (Apple-Style Authentic FFT Equalizer with Bass-Ceiling Surge)
        if vizWidth > 0 {
            let startX = vizX
            let clipPath = NSBezierPath()
            let maxHeight: CGFloat = 17.5
            
            for i in 0..<barCount {
                let newH = i < barHeights.count ? barHeights[i] : 2.5
                let y = (20.0 - newH) / 2.0
                let barRect = NSRect(x: startX + CGFloat(i) * (barW + barSp), y: y, width: barW, height: newH)
                clipPath.append(NSBezierPath(roundedRect: barRect, xRadius: barW / 2.0, yRadius: barW / 2.0))
            }
            
            // 1. Apple Music subtle bloom behind bars
            let theme = cachedWaveformTheme
            NSGraphicsContext.current?.saveGraphicsState()
            let outerGlow = NSShadow()
            outerGlow.shadowColor = theme.glowColor.withAlphaComponent(0.35)
            outerGlow.shadowOffset = .zero
            outerGlow.shadowBlurRadius = 3.0
            outerGlow.set()
            theme.glowColor.withAlphaComponent(0.15).setFill()
            clipPath.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            
            // 2. Vector gradient fill with TRUE-TONE album colors (no washed-out white wash)
            NSGraphicsContext.current?.saveGraphicsState()
            clipPath.addClip()
            let waveRect = NSRect(x: startX, y: (20.0 - maxHeight) / 2.0, width: vizWidth, height: maxHeight)
            if let gradient = NSGradient(colors: [theme.topColor, theme.bottomColor]) {
                gradient.draw(in: waveRect, angle: 90)
            } else {
                theme.topColor.setFill()
                clipPath.fill()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        
        // 3. Draw album art
        if let art = cachedAlbumArtImage, showAlbumArt {
            art.draw(at: NSPoint(x: artX, y: 0), from: NSRect(origin: .zero, size: art.size), operation: .copy, fraction: 1.0)
        }
        combinedImage.unlockFocus()
        
        combinedImage.isTemplate = false
        button.image = combinedImage
        button.imagePosition = .imageOnly
        button.needsDisplay = true
        
    } else {
        // No track playing
        if !isShowingIdleIcon {
            if let button = self.statusItem?.button {
                let img = NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: "Lyrics Menu Bar")
                img?.isTemplate = true
                button.image = img
                button.imagePosition = .imageOnly
            }
            isShowingIdleIcon = true
            lastMenuBarRenderKey = nil
            lastLyricsRenderKey = nil
            cachedLyricsImage = nil
            cachedAlbumArtTrackId = nil
            cachedAlbumArtImage = nil
        }
        return
    }
    }
}
