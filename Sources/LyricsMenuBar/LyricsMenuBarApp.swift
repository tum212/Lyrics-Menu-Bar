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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var glassView: HUDGlassView!
    var isGenieAnimating: Bool = false
    
    // Core Services
    var spotify = SpotifyService()
    var lyricsService = LyricsService()
    var audioAnalyzer = AudioAnalyzer()
    
    // Menu Bar State (GPU-Native Layer Canvas + 60 FPS CVDisplayLink)
    var statusItem: NSStatusItem!
    var menuBarCanvasView: MenuBarCanvasView!
    var updateTimer: Timer?
    var displayLink: CVDisplayLink?
    private let isFramePending = AtomicBool()
    private var lastDisplayLinkTick: CFTimeInterval = 0
    private var isActiveUpdating: Bool = false
    private var isShowingIdleIcon: Bool = false
    private var hasRealAlbumArt: Bool = false
    private var cachedAlbumArtTrackId: String?
    private var dynamicIslandPopStartTime: CFTimeInterval = 0
    private var currentMenuBarArtScale: CGFloat = 1.0
    private var currentMenuBarArtOpacity: CGFloat = 1.0
    private lazy var idlePlaySymbol: NSImage? = {
        let img = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Lyrics Menu Bar")
        img?.isTemplate = true
        return img
    }()
    
    private var lastWaveformBarsCount: Int = -1
    private var lastShowAlbumArt = true
    private var lastShowLyrics = true
    private var cachedWaveformBars: Int = 14
    private var cachedShowAlbumArt: Bool = true
    private var cachedShowLyrics: Bool = true
    private var cachedLyricsMaxWidth: Int = 200
    private var lastMeasuredText: String = ""
    private var lastMeasuredSize: NSSize = .zero
    private let menuBarFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    private lazy var menuBarAttributes: [NSAttributedString.Key: Any] = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byTruncatingTail
        return [.font: menuBarFont, .paragraphStyle: paragraphStyle]
    }()
    var cancellables = Set<AnyCancellable>()
    // Lyrics Animation State
    var lastLyricsId: UUID?
    var animatedWidth: CGFloat = 20.0
    var lastRenderedLyricsText: String = ""
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
        refreshCachedPrefs()
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleUltraLightModeChanged), name: Notification.Name("UltraLightModeChanged"), object: nil)
        
        let contentView = ContentView(
            musicService: spotify,
            lyricsService: lyricsService,
            audioAnalyzer: audioAnalyzer
        )
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating

        // Setup Native GPU Glass Backdrop
        let glassView = HUDGlassView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 480, height: 240))
        glassView.autoresizingMask = [.width, .height]
        self.glassView = glassView
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = glassView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        glassView.addSubview(hostingView)
        panel.contentView = glassView
        panel.delegate = self
        self.panel = panel
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleClosePopover), name: Notification.Name("ClosePopover"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleDistributedTogglePopover), name: NSNotification.Name("com.spoticat.TogglePopover"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioFeaturesDisabled), name: Notification.Name("AudioFeaturesDisabled"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioFeaturesEnabled), name: Notification.Name("AudioFeaturesEnabled"), object: nil)
        
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = self.statusItem.button {
            button.image = idlePlaySymbol
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover(_:))
            button.target = self
            
            let canvas = MenuBarCanvasView(frame: button.bounds)
            canvas.autoresizingMask = [.width, .height]
            canvas.isHidden = true
            button.addSubview(canvas)
            self.menuBarCanvasView = canvas
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
                self.syncMenuBarTimerState()
                self.updateMenuBar()
            }
            .store(in: &cancellables)
            
        spotify.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                if AppCapabilities.supportsAudioTap {
                    let waveformBars = self.cachedWaveformBars
                    let featuresEnabled = UserDefaults.standard.bool(forKey: "audioFeaturesEnabled")
                    if isPlaying && waveformBars > 0 && featuresEnabled {
                        self.audioAnalyzer.start()
                    } else {
                        self.audioAnalyzer.stop()
                    }
                }
                if !isPlaying {
                    self.transitionProgress = 1.0
                }
                self.syncMenuBarTimerState()
                self.updateMenuBar()
            }
            .store(in: &cancellables)
        
        spotify.$artworkRevision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBar()
            }
            .store(in: &cancellables)
        
        lyricsService.$lyrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.forceRedrawLyrics = true
                self?.updateMenuBar()
            }
            .store(in: &cancellables)
        
        // Start locked 60 FPS GPU-native CVDisplayLink updater (auto-sleeps at 0 Hz when idle/paused)
        syncMenuBarTimerState()
        updateMenuBar()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePopover(nil)
        return true
    }
    
    private func computeButtonGeometry() -> (screenFrame: NSRect, xPos: CGFloat, yPos: CGFloat, anchorX: CGFloat) {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 240
        
        var xPos: CGFloat
        var yPos: CGFloat
        var buttonMidX: CGFloat = screenFrame.maxX - 100
        
        if let button = statusItem?.button, let buttonWindow = button.window, buttonWindow.frame.origin.y > 0 {
            let buttonRect = buttonWindow.convertToScreen(button.frame)
            buttonMidX = buttonRect.midX
            xPos = buttonMidX - (panelWidth / 2)
            yPos = buttonRect.minY - panelHeight - 8
        } else {
            xPos = screenFrame.maxX - panelWidth - 20
            yPos = screenFrame.maxY - panelHeight - 8
        }
        
        // Clamp within screen boundaries
        xPos = max(screenFrame.minX + 10, min(xPos, screenFrame.maxX - panelWidth - 10))
        yPos = max(screenFrame.minY + 10, min(yPos, screenFrame.maxY - panelHeight - 8))
        
        let rawAnchorX = (buttonMidX - xPos) / panelWidth
        let anchorX = max(0.06, min(0.94, rawAnchorX))
        
        return (screenFrame, xPos, yPos, anchorX)
    }

    private func animateGenieOpen() {
        guard let panel = self.panel, let glassView = self.glassView, let layer = glassView.layer else { return }
        isGenieAnimating = true
        
        let geom = computeButtonGeometry()
        panel.setFrame(NSRect(x: geom.xPos, y: geom.yPos, width: 480, height: 240), display: true)
        panel.invalidateShadow()
        
        if AppPerformance.isUltraLightMode {
            // Snappy 60 FPS 2D spring open for Intel iGPU (zero expensive 3D m34 perspective warp)
            layer.anchorPoint = CGPoint(x: geom.anchorX, y: 1.0)
            layer.position = CGPoint(x: 480 * geom.anchorX, y: 240 * 1.0)
            let startTransform = CATransform3DMakeScale(0.94, 0.94, 1.0)
            layer.transform = startTransform
            layer.opacity = 0.0
            
            spotify.isPanelVisible = true
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            
            let springAnim = CASpringAnimation(keyPath: "transform")
            springAnim.mass = 1.0
            springAnim.stiffness = 320.0
            springAnim.damping = 28.0
            springAnim.fromValue = NSValue(caTransform3D: startTransform)
            springAnim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            springAnim.duration = springAnim.settlingDuration
            
            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 0.0
            fadeAnim.toValue = 1.0
            fadeAnim.duration = 0.16
            fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                layer.transform = CATransform3DIdentity
                layer.opacity = 1.0
                self?.isGenieAnimating = false
            }
            layer.add(springAnim, forKey: "liteOpenSpring")
            layer.add(fadeAnim, forKey: "liteOpenOpacity")
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
            CATransaction.commit()
            return
        }
        
        // 1. Setup Layer Geometry for Top Anchor Point directly beneath Menu Bar Item
        let anchor = CGPoint(x: geom.anchorX, y: 1.0)
        layer.anchorPoint = anchor
        layer.position = CGPoint(x: 480 * geom.anchorX, y: 240 * 1.0)
        
        // 2. Initial Collapsed 3D Funnel Transform
        var collapsed = CATransform3DIdentity
        collapsed.m34 = -1.0 / 600.0 // Perspective projection
        collapsed = CATransform3DTranslate(collapsed, 0, 15, 0)
        collapsed = CATransform3DScale(collapsed, 0.05, 0.02, 1.0)
        collapsed = CATransform3DRotate(collapsed, CGFloat(12.0 * .pi / 180.0), 1, 0, 0)
        
        layer.transform = collapsed
        layer.opacity = 0.0
        
        spotify.isPanelVisible = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // 3. Apple Spring Physics for fluid, non-jerking opening
        let springAnim = CASpringAnimation(keyPath: "transform")
        springAnim.mass = 1.0
        springAnim.stiffness = 175.0
        springAnim.damping = 22.0
        springAnim.fromValue = NSValue(caTransform3D: collapsed)
        springAnim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        springAnim.duration = springAnim.settlingDuration
        
        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 0.0
        fadeAnim.toValue = 1.0
        fadeAnim.duration = 0.30
        fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
            self?.isGenieAnimating = false
        }
        layer.add(springAnim, forKey: "genieOpenTransform")
        layer.add(fadeAnim, forKey: "genieOpenOpacity")
        layer.transform = CATransform3DIdentity
        layer.opacity = 1.0
        CATransaction.commit()
    }

    private func animateGenieClose() {
        guard self.panel != nil, let glassView = self.glassView, let layer = glassView.layer else { return }
        isGenieAnimating = true
        
        if AppPerformance.isUltraLightMode {
            let endTransform = CATransform3DMakeScale(0.95, 0.95, 1.0)
            let scaleAnim = CABasicAnimation(keyPath: "transform")
            scaleAnim.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            scaleAnim.toValue = NSValue(caTransform3D: endTransform)
            scaleAnim.duration = 0.14
            scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            
            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 1.0
            fadeAnim.toValue = 0.0
            fadeAnim.duration = 0.14
            fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self = self else { return }
                self.spotify.isPanelVisible = false
                self.panel.orderOut(nil)
                layer.transform = CATransform3DIdentity
                layer.opacity = 1.0
                self.isGenieAnimating = false
            }
            layer.add(scaleAnim, forKey: "liteCloseScale")
            layer.add(fadeAnim, forKey: "liteCloseOpacity")
            layer.transform = endTransform
            layer.opacity = 0.0
            CATransaction.commit()
            return
        }
        
        let geom = computeButtonGeometry()
        let anchor = CGPoint(x: geom.anchorX, y: 1.0)
        layer.anchorPoint = anchor
        layer.position = CGPoint(x: 480 * geom.anchorX, y: 240 * 1.0)
        
        var collapsed = CATransform3DIdentity
        collapsed.m34 = -1.0 / 600.0
        collapsed = CATransform3DTranslate(collapsed, 0, 15, 0)
        collapsed = CATransform3DScale(collapsed, 0.05, 0.02, 1.0)
        collapsed = CATransform3DRotate(collapsed, CGFloat(12.0 * .pi / 180.0), 1, 0, 0)
        
        let transformAnim = CABasicAnimation(keyPath: "transform")
        transformAnim.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        transformAnim.toValue = NSValue(caTransform3D: collapsed)
        transformAnim.duration = 0.28
        transformAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        
        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 1.0
        fadeAnim.toValue = 0.0
        fadeAnim.duration = 0.24
        fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self else { return }
            self.spotify.isPanelVisible = false
            self.panel.orderOut(nil)
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
            self.isGenieAnimating = false
        }
        layer.add(transformAnim, forKey: "genieCloseTransform")
        layer.add(fadeAnim, forKey: "genieCloseOpacity")
        layer.transform = collapsed
        layer.opacity = 0.0
        CATransaction.commit()
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        guard let panel = self.panel else { return }
        if isGenieAnimating { return }
        
        if panel.isVisible {
            animateGenieClose()
        } else {
            animateGenieOpen()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopMenuBarUpdater()
        audioAnalyzer.stop()
        if AppCapabilities.supportsAudioTap {
            HapticManager.shared.teardown()
        }
        spotify.cleanup()
    }
    
    @objc private func handleClosePopover() {
        if panel?.isVisible == true && !isGenieAnimating {
            animateGenieClose()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == panel {
            if panel?.isVisible == true && !isGenieAnimating {
                animateGenieClose()
            }
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
    
    private func refreshCachedPrefs() {
        let ud = UserDefaults.standard
        if ud.object(forKey: "waveformBars") != nil {
            cachedWaveformBars = min(128, max(0, ud.integer(forKey: "waveformBars")))
        } else {
            cachedWaveformBars = (AppPerformance.isUltraLightMode || !AppCapabilities.supportsAudioTap) ? 0 : 14
        }
        cachedShowAlbumArt = ud.object(forKey: "showAlbumArt") != nil ? ud.bool(forKey: "showAlbumArt") : true
        cachedShowLyrics = ud.object(forKey: "showLyrics") != nil ? ud.bool(forKey: "showLyrics") : true
        if ud.object(forKey: "lyricsMaxWidth") != nil {
            cachedLyricsMaxWidth = ud.integer(forKey: "lyricsMaxWidth")
        } else {
            cachedLyricsMaxWidth = 200
        }
    }
    
    @objc private func handleUserDefaultsChanged() {
        refreshCachedPrefs()
        syncMenuBarTimerState()
        forceRedrawLyrics = true
        updateMenuBar()
    }
    
    @objc private func handleUltraLightModeChanged() {
        refreshCachedPrefs()
        syncMenuBarTimerState()
        forceRedrawLyrics = true
        updateMenuBar()
    }
    
    func syncMenuBarTimerState() {
        let isPausedSettling = (spotify.currentTrack != nil && !spotify.isPlaying) &&
            (abs(currentMenuBarArtScale - 0.82) > 0.005 || transitionProgress < 1.0)
        let needsActiveFrames = (spotify.currentTrack != nil) && (spotify.isPlaying || isPausedSettling)
        
        if !needsActiveFrames {
            if isActiveUpdating {
                stopMenuBarUpdater()
            }
            return
        }
        
        if isActiveUpdating && (displayLink != nil || updateTimer != nil) {
            return
        }
        
        stopMenuBarUpdater()
        isActiveUpdating = true
        lastFrameTime = Date()
        
        var link: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let activeLink = link {
            let frameGate = self.isFramePending
            let status = CVDisplayLinkSetOutputHandler(activeLink) { [weak self] _, _, _, _, _ in
                guard frameGate.testAndSet() else { return kCVReturnSuccess }
                DispatchQueue.main.async {
                    defer { frameGate.reset() }
                    self?.displayLinkTick()
                }
                return kCVReturnSuccess
            }
            if status == kCVReturnSuccess && CVDisplayLinkStart(activeLink) == kCVReturnSuccess {
                self.displayLink = activeLink
                return
            }
        }
        
        // Fallback 60 FPS Timer if CVDisplayLink could not attach
        let timer = Timer.scheduledTimer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(timerTick), userInfo: nil, repeats: true)
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }
    
    func startMenuBarUpdater() {
        syncMenuBarTimerState()
    }
    
    func stopMenuBarUpdater() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            self.displayLink = nil
        }
        updateTimer?.invalidate()
        updateTimer = nil
        isActiveUpdating = false
    }
    
    private func displayLinkTick() {
        let now = CACurrentMediaTime()
        // Cap 120Hz ProMotion panels to locked 60 FPS while running native 60Hz VSync everywhere
        if now - lastDisplayLinkTick < (1.0 / 62.0) { return }
        lastDisplayLinkTick = now
        updateMenuBar()
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
    
    
    
    func updateMenuBar() {
        let now = Date()
        if Int(now.timeIntervalSince1970 * 10) % 20 == 0 {
            logDebug("updateMenuBar: track=\(spotify.currentTrack?.name ?? "nil"), statusWinFrame=\(statusItem?.button?.window?.frame as Any), isVis=\(statusItem?.isVisible ?? false)")
        }
        var deltaTime = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now
        let isUltraLight = AppPerformance.isUltraLightMode
        if deltaTime > 0.25 || deltaTime <= 0 { deltaTime = 0.016 }
        
        let waveformBars = cachedWaveformBars
        let showAlbumArt = cachedShowAlbumArt
        let showLyrics = cachedShowLyrics
        
        // Pass dynamic band count to audio analyzer
        if waveformBars > 0 && AppCapabilities.supportsAudioTap {
            audioAnalyzer.updateBandCount(waveformBars)
        }
        
        // Check for state changes to force redraw
        let prefsChanged = (waveformBars != lastWaveformBarsCount || showAlbumArt != lastShowAlbumArt || showLyrics != lastShowLyrics)
        if prefsChanged {
            lastWaveformBarsCount = waveformBars
            lastShowAlbumArt = showAlbumArt
            lastShowLyrics = showLyrics
        }
        
        let isVisible = showLyrics || (waveformBars > 0) || showAlbumArt || (spotify.currentTrack == nil)
        if statusItem?.isVisible != isVisible {
            statusItem?.isVisible = isVisible
        }
        
        if let track = spotify.currentTrack {
            guard let button = self.statusItem?.button else { return }
            if isShowingIdleIcon || button.image != nil {
                button.image = nil
                menuBarCanvasView?.isHidden = false
                isShowingIdleIcon = false
            }
            let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            
            if lastTrackIdForSparkle != track.id {
                lastTrackIdForSparkle = track.id
                trackChangedTime = now
            }
            let sparkleTime = now.timeIntervalSince(trackChangedTime)
            
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
            
            let attributes = menuBarAttributes
            let textSize: NSSize
            if currentLineText == lastMeasuredText {
                textSize = lastMeasuredSize
            } else {
                textSize = currentLineText.size(withAttributes: attributes)
                lastMeasuredText = currentLineText
                lastMeasuredSize = textSize
            }
            
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
            
            let lyricsMaxWidth = cachedLyricsMaxWidth
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
                lastWordLeadX = nil
                oldMarqueeOffset = marqueeOffset
                lastRenderedLyricsText = currentLineText
                transitionProgress = 0.0
                
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
            
            let targetOrbAlpha: CGFloat = (progress > 0.0 && progress < 1.0) ? 1.0 : 0.0
            let alphaSmoothing = CGFloat(1.0 - exp(-15.0 * deltaTime))
            animatedOrbAlpha += (targetOrbAlpha - animatedOrbAlpha) * alphaSmoothing
            
            let totalSparkleDuration = 5.5
            let isSparkling = !isUltraLight && (lyricsService.isLoading || (sparkleTime < totalSparkleDuration && currentLineText == track.name))
            let sparkleCycleTime = lyricsService.isLoading ? sparkleTime.truncatingRemainder(dividingBy: totalSparkleDuration) : sparkleTime
            
            // --- 2. ART & WAVEFORM UPDATING ---
            let artKey = "\(track.id)_\(spotify.artworkRevision)"
            if cachedAlbumArtTrackId != artKey {
                let shouldCrossfade = (cachedAlbumArtTrackId != nil)
                cachedAlbumArtTrackId = artKey
                if shouldCrossfade {
                    dynamicIslandPopStartTime = CACurrentMediaTime()
                }
                
                if let directImage = spotify.activeArtworkImage {
                    hasRealAlbumArt = true
                    menuBarCanvasView?.setArtwork(
                        directImage,
                        artKey: artKey,
                        isFallbackSymbol: false,
                        isDark: isDark,
                        crossfadePrevious: shouldCrossfade
                    )
                    if cachedWaveformBars > 0 {
                        self.cachedWaveformTheme = ColorExtractor.extractWaveformTheme(from: directImage)
                    } else {
                        self.cachedWaveformTheme = .fallback
                    }
                } else {
                    hasRealAlbumArt = false
                    menuBarCanvasView?.setArtwork(
                        idlePlaySymbol,
                        artKey: "fallback_\(isDark ? 1 : 0)",
                        isFallbackSymbol: true,
                        isDark: isDark,
                        crossfadePrevious: false
                    )
                    self.cachedWaveformTheme = .fallback
                }
            }
            
            let barCount = cachedWaveformBars
            let barW: CGFloat = 2.0
            let barSp: CGFloat = 1.5
            let vizWidth: CGFloat = (barCount > 0 && spotify.isPlaying) ? CGFloat(barCount) * (barW + barSp) : 0
            let artWidth: CGFloat = showAlbumArt ? 20.0 : 0
            let lyricsWidth: CGFloat = (showLyrics && canvasWidth > 2) ? canvasWidth : 0
            
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
            
            // Update album art breathe / play-pause scale smoothly at 60 FPS
            let targetArtScale: CGFloat = spotify.isPlaying ? 1.0 : 0.82
            let targetArtOpacity: CGFloat = spotify.isPlaying ? 1.0 : 0.74
            let artLerp = CGFloat(1.0 - exp(-10.0 * deltaTime))
            currentMenuBarArtScale += (targetArtScale - currentMenuBarArtScale) * artLerp
            currentMenuBarArtOpacity += (targetArtOpacity - currentMenuBarArtOpacity) * artLerp
            if abs(targetArtScale - currentMenuBarArtScale) < 0.004 {
                currentMenuBarArtScale = targetArtScale
                currentMenuBarArtOpacity = targetArtOpacity
            }
            
            let popElapsedRaw = CACurrentMediaTime() - dynamicIslandPopStartTime
            let popElapsed: TimeInterval? = (dynamicIslandPopStartTime > 0 && popElapsedRaw < 0.75) ? popElapsedRaw : nil
            
            if let item = self.statusItem, abs(item.length - quantizedWidth) > 0.5 {
                item.length = quantizedWidth
            }
            
            if forceRedrawLyrics {
                forceRedrawLyrics = false
            }
            
            menuBarCanvasView?.renderFrame(
                currentLineText: currentLineText,
                textSize: textSize,
                glowPad: glowPad,
                showLyrics: showLyrics && canvasWidth > 2,
                lyricsX: lyricsX,
                canvasWidth: canvasWidth,
                marqueeOffset: marqueeOffset,
                oldMarqueeOffset: oldMarqueeOffset,
                transitionProgress: transitionProgress,
                progress: progress,
                wordLeadX: wordLeadX,
                animatedOrbAlpha: animatedOrbAlpha,
                isDark: isDark,
                isSparkling: isSparkling,
                sparkleCycleTime: sparkleCycleTime,
                nowTime: now.timeIntervalSinceReferenceDate,
                showWaveform: vizWidth > 0,
                vizX: vizX,
                vizWidth: vizWidth,
                barHeights: barHeights,
                barW: barW,
                barSp: barSp,
                waveformTheme: cachedWaveformTheme,
                showAlbumArt: showAlbumArt,
                artX: artX,
                artScale: currentMenuBarArtScale,
                popElapsed: popElapsed,
                artOpacity: currentMenuBarArtOpacity
            )
            
            if !spotify.isPlaying && isActiveUpdating {
                syncMenuBarTimerState()
            }
            
        } else {
            // No track playing — render clean play icon and sleep at 0 Hz
            if !isShowingIdleIcon {
                menuBarCanvasView?.isHidden = true
                menuBarCanvasView?.reset()
                if let button = self.statusItem?.button {
                    button.image = idlePlaySymbol
                    button.imagePosition = .imageOnly
                }
                if let item = self.statusItem, item.length != NSStatusItem.variableLength {
                    item.length = NSStatusItem.variableLength
                }
                isShowingIdleIcon = true
                cachedAlbumArtTrackId = nil
                hasRealAlbumArt = false
                lastRenderedLyricsText = ""
                oldLineText = ""
                stopMenuBarUpdater()
            }
            return
        }
    }
}
