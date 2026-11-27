import AppKit
import CLyricsCore
import Cocoa
import CoreVideo
import QuartzCore
import os

@main
struct SpoticatApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    var hudContentView: HUDContentView!
    var isGenieAnimating: Bool = false

    // Rust Core + Thin Bridges
    let coreEngine = LyricsCoreEngine.shared
    let audioTap = AudioTapBridge.shared
    let musicIPC = MusicIPCBridge.shared

    // Menu Bar State (GPU-Native CALayer Canvas + 60 FPS CVDisplayLink)
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
    private var needsActiveFramesFromRust: Bool = false
    private var isSystemAsleep: Bool = false

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

    // Lyrics Animation State
    var lastRenderedLyricsText: String = ""
    var lastWordLeadX: CGFloat?
    var marqueeOffset: CGFloat = 16.0
    var oldMarqueeOffset: CGFloat = 16.0
    var lastFrameTime: Date = Date()
    var barHeights: [CGFloat] = []
    var cachedWaveformTheme: WaveformThemeModel = .fallback
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppDefaults.register()
        refreshCachedPrefs()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleUserDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleUltraLightModeChanged), name: Notification.Name("UltraLightModeChanged"), object: nil)
        nc.addObserver(self, selector: #selector(handleClosePopover), name: Notification.Name("ClosePopover"), object: nil)
        nc.addObserver(self, selector: #selector(handleAudioFeaturesDisabled), name: Notification.Name("AudioFeaturesDisabled"), object: nil)
        nc.addObserver(self, selector: #selector(handleAudioFeaturesEnabled), name: Notification.Name("AudioFeaturesEnabled"), object: nil)
        nc.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleModalPresentationEnded), name: SettingsMenuController.modalPresentationDidEndNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleLowPowerModeChanged), name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(handleSystemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(handleSystemDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleDistributedTogglePopover), name: NSNotification.Name("com.spoticat.TogglePopover"), object: nil)

        // Setup KeyablePanel + HUDGlassView + Pure AppKit HUDContentView (ZERO SwiftUI)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Always enforce dark glass appearance so white HUD typography & icons remain crisp in macOS Light Mode
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating

        let glassView = HUDGlassView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        glassView.autoresizingMask = [.width, .height]
        self.glassView = glassView

        let hudContent = HUDContentView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        hudContent.autoresizingMask = [.width, .height]
        self.hudContentView = hudContent
        glassView.addSubview(hudContent)

        panel.contentView = glassView
        panel.delegate = self
        self.panel = panel

        // Setup Status Bar Item + GPU-Native CALayer Canvas
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = self.statusItem.button {
            button.image = idlePlaySymbol
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover(_:))
            button.target = self

            let canvas = MenuBarCanvasView(frame: button.bounds)
            canvas.autoresizingMask = [.width, .height]
            canvas.isHidden = true
            canvas.onAppearanceOrScaleChanged = { [weak self] in
                self?.updateMenuBar()
            }
            button.addSubview(canvas)
            self.menuBarCanvasView = canvas
        }

        // Subscribe to RustCore events
        observers.append(nc.addObserver(forName: LyricsCoreEngine.trackDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastWordLeadX = nil
                    self.syncAudioTapState()
                    self.needsActiveFramesFromRust = true
                    self.syncMenuBarTimerState()
                    self.updateMenuBar()
                }
            }
        })

        observers.append(nc.addObserver(forName: LyricsCoreEngine.playStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncAudioTapState()
                    self.needsActiveFramesFromRust = true
                    self.syncMenuBarTimerState()
                    self.updateMenuBar()
                }
            }
        })

        observers.append(nc.addObserver(forName: LyricsCoreEngine.playbackDidSeekNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastWordLeadX = nil
                    self.needsActiveFramesFromRust = true
                    self.syncMenuBarTimerState()
                    self.updateMenuBar()
                }
            }
        })

        observers.append(nc.addObserver(forName: LyricsCoreEngine.artworkDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.needsActiveFramesFromRust = true
                    self.syncMenuBarTimerState()
                    self.updateMenuBar()
                }
            }
        })

        observers.append(nc.addObserver(forName: LyricsCoreEngine.lyricsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastWordLeadX = nil
                    self.updateMenuBar()
                }
            }
        })

        syncAudioTapState()
        syncMenuBarTimerState()
        updateMenuBar()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePopover(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMenuBarUpdater()
        audioTap.stop()
        musicIPC.cleanup()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - System Sleep / Wake / Screen Hot-Plug Resilience

    @objc private func handleSystemWillSleep() {
        isSystemAsleep = true
        stopMenuBarUpdater()
        audioTap.stop()
    }

    @objc private func handleSystemDidWake() {
        isSystemAsleep = false
        syncAudioTapState()
        syncMenuBarTimerState()
        musicIPC.pollActivePlayer()
        updateMenuBar()
    }

    @objc private func handleScreenParametersChanged() {
        if isActiveUpdating {
            // Recreate CVDisplayLink so it binds to updated displays
            stopMenuBarUpdater()
            syncMenuBarTimerState()
        }
        updateMenuBar()
    }

    @objc private func handleLowPowerModeChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.handleUltraLightModeChanged()
        }
    }

    @objc private func handleModalPresentationEnded() {
        guard let panel = self.panel, panel.isVisible, !isGenieAnimating else { return }
        if !NSApp.isActive {
            // User clicked outside to dismiss the menu — close HUD cleanly instead of leaving it orphaned
            if !isUpdateInProgress() {
                animateGenieClose()
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func isUpdateInProgress() -> Bool {
        switch coreEngine.updateState {
        case .downloading, .installing:
            return true
        default:
            return false
        }
    }

    // MARK: - Panel Genie & 60 FPS Spring Open/Close

    private func computeButtonGeometry() -> (screenFrame: NSRect, xPos: CGFloat, yPos: CGFloat, anchorX: CGFloat) {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 240

        var xPos: CGFloat
        var yPos: CGFloat
        var buttonMidX: CGFloat = screenFrame.maxX - 100

        if let button = statusItem?.button, let buttonWindow = button.window {
            let rectInWindow = button.convert(button.bounds, to: nil)
            let buttonRect = buttonWindow.convertToScreen(rectInWindow)
            if buttonRect.width > 0 && buttonRect.height > 0 {
                buttonMidX = buttonRect.midX
                xPos = buttonMidX - (panelWidth / 2)
                yPos = buttonRect.minY - panelHeight - 8
            } else {
                xPos = screenFrame.maxX - panelWidth - 20
                yPos = screenFrame.maxY - panelHeight - 8
            }
        } else {
            xPos = screenFrame.maxX - panelWidth - 20
            yPos = screenFrame.maxY - panelHeight - 8
        }

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

        coreEngine.isPanelVisible = true
        hudContentView?.lyricsView.snapScrollToActive()
        hudContentView?.lyricsView.renderNow(force: true)
        syncMenuBarTimerState()

        if AppPerformance.isUltraLightMode {
            layer.anchorPoint = CGPoint(x: geom.anchorX, y: 1.0)
            layer.position = CGPoint(x: 480 * geom.anchorX, y: 240 * 1.0)
            let startTransform = CATransform3DMakeScale(0.94, 0.94, 1.0)
            layer.transform = startTransform
            layer.opacity = 0.0

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
                guard let self else { return }
                layer.transform = CATransform3DIdentity
                layer.opacity = 1.0
                self.isGenieAnimating = false
                if !panel.isKeyWindow && !SettingsMenuController.isPresentingModal && !self.isUpdateInProgress() {
                    self.animateGenieClose()
                }
            }
            layer.add(springAnim, forKey: "liteOpenSpring")
            layer.add(fadeAnim, forKey: "liteOpenOpacity")
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
            CATransaction.commit()
            return
        }

        let anchor = CGPoint(x: geom.anchorX, y: 1.0)
        layer.anchorPoint = anchor
        layer.position = CGPoint(x: 480 * geom.anchorX, y: 240 * 1.0)

        var collapsed = CATransform3DIdentity
        collapsed.m34 = -1.0 / 600.0
        collapsed = CATransform3DTranslate(collapsed, 0, 15, 0)
        collapsed = CATransform3DScale(collapsed, 0.05, 0.02, 1.0)
        collapsed = CATransform3DRotate(collapsed, CGFloat(12.0 * .pi / 180.0), 1, 0, 0)

        layer.transform = collapsed
        layer.opacity = 0.0

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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
            guard let self else { return }
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
            self.isGenieAnimating = false
            if !panel.isKeyWindow && !SettingsMenuController.isPresentingModal && !self.isUpdateInProgress() {
                self.animateGenieClose()
            }
        }
        layer.add(springAnim, forKey: "genieOpenTransform")
        layer.add(fadeAnim, forKey: "genieOpenOpacity")
        layer.transform = CATransform3DIdentity
        layer.opacity = 1.0
        CATransaction.commit()
    }

    private func finishPanelCloseCleanup(panel: NSPanel, layer: CALayer) {
        coreEngine.isPanelVisible = false
        panel.orderOut(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.opacity = 1.0
        CATransaction.commit()
        NSCursor.arrow.set()
        hudContentView?.lyricsView.purgeImageCache()
        isGenieAnimating = false
        syncMenuBarTimerState()
    }

    private func animateGenieClose() {
        guard let panel = self.panel, let glassView = self.glassView, let layer = glassView.layer else { return }
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
                self?.finishPanelCloseCleanup(panel: panel, layer: layer)
            }
            layer.add(scaleAnim, forKey: "liteCloseScale")
            layer.add(fadeAnim, forKey: "liteCloseOpacity")
            layer.transform = endTransform
            layer.opacity = 0.0
            CATransaction.commit()
            return
        }

        let geom = computeButtonGeometry()
        layer.anchorPoint = CGPoint(x: geom.anchorX, y: 1.0)
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
            self?.finishPanelCloseCleanup(panel: panel, layer: layer)
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

    @objc private func handleClosePopover() {
        if panel?.isVisible == true && !isGenieAnimating {
            animateGenieClose()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !SettingsMenuController.isPresentingModal else { return }
        guard !isUpdateInProgress() else { return }
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
        syncAudioTapState()
    }

    @objc private func handleAudioFeaturesEnabled() {
        syncAudioTapState()
    }

    private func syncAudioTapState() {
        guard AppCapabilities.supportsAudioTap, !isSystemAsleep else { return }
        let featuresEnabled = UserDefaults.standard.bool(forKey: AppSettingKey.audioFeaturesEnabled)
        let hapticIntensity = UserDefaults.standard.integer(forKey: AppSettingKey.hapticIntensity)
        let needsTap = coreEngine.currentTrack != nil
            && coreEngine.isPlaying
            && featuresEnabled
            && (cachedWaveformBars > 0 || hapticIntensity > 0)
        if needsTap {
            if cachedWaveformBars > 0 {
                coreEngine.updateWaveformBandCount(cachedWaveformBars)
            }
            audioTap.start()
        } else {
            audioTap.stop()
        }
    }

    // MARK: - Preferences & 60 FPS CVDisplayLink Scheduler

    private func refreshCachedPrefs() {
        let ud = UserDefaults.standard
        if ud.object(forKey: AppSettingKey.waveformBars) != nil {
            cachedWaveformBars = min(128, max(0, ud.integer(forKey: AppSettingKey.waveformBars)))
        } else {
            cachedWaveformBars = (AppPerformance.isUltraLightMode || !AppCapabilities.supportsAudioTap) ? 0 : 14
        }
        cachedShowAlbumArt = ud.object(forKey: AppSettingKey.showAlbumArt) != nil ? ud.bool(forKey: AppSettingKey.showAlbumArt) : true
        cachedShowLyrics = ud.object(forKey: AppSettingKey.showLyrics) != nil ? ud.bool(forKey: AppSettingKey.showLyrics) : true
        if ud.object(forKey: AppSettingKey.lyricsMaxWidth) != nil {
            cachedLyricsMaxWidth = ud.integer(forKey: AppSettingKey.lyricsMaxWidth)
        } else {
            cachedLyricsMaxWidth = 200
        }
    }

    @objc private func handleUserDefaultsChanged() {
        let prevBars = cachedWaveformBars
        refreshCachedPrefs()
        if prevBars == 0 && cachedWaveformBars > 0, let img = coreEngine.artworkImage {
            cachedWaveformTheme = ColorExtractor.extractWaveformTheme(from: img)
        }
        syncAudioTapState()
        syncMenuBarTimerState()
        updateMenuBar()
    }

    @objc private func handleUltraLightModeChanged() {
        refreshCachedPrefs()
        glassView?.updateForPerformanceMode()
        syncAudioTapState()
        syncMenuBarTimerState()
        updateMenuBar()
    }

    private func isPopAnimationActive() -> Bool {
        let elapsed = CACurrentMediaTime() - dynamicIslandPopStartTime
        return dynamicIslandPopStartTime > 0 && elapsed < 0.75
    }

    func syncMenuBarTimerState() {
        if isSystemAsleep {
            stopMenuBarUpdater()
            return
        }
        let hasTrack = coreEngine.currentTrack != nil
        let isPlaying = coreEngine.isPlaying
        let hudVisibleAndPlaying = hasTrack && (panel?.isVisible == true) && isPlaying
        let needsActive = (hasTrack && (isPlaying || needsActiveFramesFromRust || isPopAnimationActive())) || hudVisibleAndPlaying

        if !needsActive {
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
            let status = attachDisplayLinkHandler(activeLink, frameGate: self.isFramePending) { [weak self] in
                self?.displayLinkTick()
            }
            if status == kCVReturnSuccess && CVDisplayLinkStart(activeLink) == kCVReturnSuccess {
                self.displayLink = activeLink
                return
            }
        }

        let timer = Timer.scheduledTimer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(timerTick), userInfo: nil, repeats: true)
        timer.tolerance = 0.002
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
        isActiveUpdating = false
    }

    private func displayLinkTick() {
        let now = CACurrentMediaTime()
        // Slightly under 16.6ms (1/68s = 14.7ms) prevents 60Hz jitter from skipping every other vsync to 30 FPS
        if now - lastDisplayLinkTick < (1.0 / 68.0) { return }
        lastDisplayLinkTick = now
        updateMenuBar()
    }

    @objc private func timerTick() {
        updateMenuBar()
    }

    nonisolated private func attachDisplayLinkHandler(
        _ activeLink: CVDisplayLink,
        frameGate: AtomicBool,
        onTick: @escaping @MainActor () -> Void
    ) -> CVReturn {
        CVDisplayLinkSetOutputHandler(activeLink) { _, _, _, _, _ in
            guard frameGate.testAndSet() else { return kCVReturnSuccess }
            DispatchQueue.main.async {
                defer { frameGate.reset() }
                MainActor.assumeIsolated {
                    onTick()
                }
            }
            return kCVReturnSuccess
        }
    }

    private func getNotchSafeMaxWidth() -> CGFloat {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        if #available(macOS 12.0, *), let rightArea = screen?.auxiliaryTopRightArea {
            return max(120.0, rightArea.width - 260.0)
        }
        return 600.0
    }

    private func showIdleButtonFallback() {
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
            lastWordLeadX = nil
        }
    }

    // MARK: - Unified 60 FPS GPU Frame Pass (MenuBar + Visible HUD)

    func updateMenuBar() {
        let now = Date()
        var deltaTime = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now
        let isUltraLight = AppPerformance.isUltraLightMode
        if deltaTime > 0.25 || deltaTime <= 0 { deltaTime = 0.016 }

        let waveformBars = cachedWaveformBars
        let showAlbumArt = cachedShowAlbumArt
        let showLyrics = cachedShowLyrics

        if waveformBars != lastWaveformBarsCount {
            if waveformBars > 0 && AppCapabilities.supportsAudioTap {
                coreEngine.updateWaveformBandCount(waveformBars)
            }
            if lastWaveformBarsCount <= 0 && waveformBars > 0, let img = coreEngine.artworkImage {
                cachedWaveformTheme = ColorExtractor.extractWaveformTheme(from: img)
            }
            lastWaveformBarsCount = waveformBars
        }
        lastShowAlbumArt = showAlbumArt
        lastShowLyrics = showLyrics

        // NEVER hide statusItem completely — user must always have a clickable entry point in the Menu Bar!
        if statusItem?.isVisible == false {
            statusItem?.isVisible = true
        }

        let step = coreEngine.stepMenuBarFrame(deltaTime: deltaTime, isUltraLight: isUltraLight)
        needsActiveFramesFromRust = step.needsActiveFrames

        if step.hasTrack, let track = coreEngine.currentTrack {
            guard let button = self.statusItem?.button else { return }

            let barCount = cachedWaveformBars
            let barW: CGFloat = 2.0
            let barSp: CGFloat = 1.5
            let vizWidth: CGFloat = (barCount > 0 && coreEngine.isPlaying) ? CGFloat(barCount) * (barW + barSp) : 0
            let artWidth: CGFloat = showAlbumArt ? 20.0 : 0
            let lyricsRequested = showLyrics && cachedLyricsMaxWidth > 2

            // If user turned off lyrics, album art, AND waveform is inactive, keep clickable idle icon visible!
            if !lyricsRequested && vizWidth <= 0 && artWidth <= 0 {
                showIdleButtonFallback()
                if panel?.isVisible == true {
                    hudContentView?.lyricsView.renderFrame(
                        currentTime: coreEngine.currentTime(),
                        deltaTime: deltaTime,
                        isPlaying: coreEngine.isPlaying
                    )
                }
                if !step.needsActiveFrames && !(panel?.isVisible == true && coreEngine.isPlaying) {
                    syncMenuBarTimerState()
                }
                return
            }

            if isShowingIdleIcon || button.image != nil {
                button.image = nil
                menuBarCanvasView?.isHidden = false
                isShowingIdleIcon = false
            } else if menuBarCanvasView?.isHidden == true {
                menuBarCanvasView?.isHidden = false
            }

            let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let currentLineText = step.text

            let textSize: NSSize
            if currentLineText == lastMeasuredText {
                textSize = lastMeasuredSize
            } else {
                textSize = currentLineText.size(withAttributes: menuBarAttributes)
                lastMeasuredText = currentLineText
                lastMeasuredSize = textSize
            }

            let fadeWidth: CGFloat = 24.0
            var wordLeadX: CGFloat? = nil
            if step.isUnsynced || step.activeWordAfterEnd {
                wordLeadX = textSize.width + fadeWidth
            } else if step.activeWordBeforeStart {
                wordLeadX = -fadeWidth
            } else if step.activeWordIndex >= 0,
                      let activeLine = coreEngine.lyrics.first(where: { $0.id == step.lineId }),
                      step.activeWordIndex < activeLine.words.count {
                var searchStart = currentLineText.startIndex
                var resolvedX: CGFloat? = nil
                for wi in 0...step.activeWordIndex {
                    let wordText = activeLine.words[wi].text
                    if let r = currentLineText.range(of: wordText, range: searchStart..<currentLineText.endIndex) {
                        searchStart = r.upperBound
                        if wi == step.activeWordIndex {
                            let prefix = String(currentLineText[..<r.lowerBound])
                            let prefixW = prefix.size(withAttributes: menuBarAttributes).width
                            let wordW = wordText.size(withAttributes: menuBarAttributes).width
                            resolvedX = prefixW + wordW * CGFloat(step.activeWordProgress)
                        }
                    }
                }
                if var rx = resolvedX {
                    if let lastX = lastWordLeadX, currentLineText == lastRenderedLyricsText {
                        rx = max(lastX, rx)
                    }
                    lastWordLeadX = rx
                    wordLeadX = rx
                }
            }

            // Enforce total notch-safe budget across lyrics + waveform + album art + gaps
            let gap: CGFloat = 8.0
            let notchBudget = getNotchSafeMaxWidth()
            let nonLyricsW = vizWidth + artWidth
                + (vizWidth > 0 && artWidth > 0 ? gap : 0)
                + ((vizWidth > 0 || artWidth > 0) && lyricsRequested ? gap : 0)
            let availLyricsBudget = max(0.0, notchBudget - nonLyricsW)
            let effectiveMaxW = min(CGFloat(cachedLyricsMaxWidth), availLyricsBudget)
            let neededW = ceil(textSize.width) + 32.0
            let canvasWidth: CGFloat = lyricsRequested && effectiveMaxW >= 40.0
                ? min(effectiveMaxW, max(60.0, neededW))
                : 0.0

            let glowPad: CGFloat = 6.0
            let scrollPadding: CGFloat = 16.0
            let fullTextWidth = textSize.width + glowPad * 2
            let effectiveWidth = canvasWidth - scrollPadding * 2
            let isMarquee = canvasWidth > 0 && fullTextWidth > effectiveWidth && currentLineText != "♪"

            var targetOffset: CGFloat = scrollPadding
            if isMarquee {
                let maxScroll = fullTextWidth - effectiveWidth
                if step.isUnsynced {
                    let scrollSpeed: CGFloat = 38.0
                    let travelTime = Double(maxScroll / scrollSpeed)
                    let pauseTime = 1.6
                    let fullCycle = travelTime + pauseTime * 2
                    let cycleT = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: fullCycle)
                    if cycleT < pauseTime {
                        targetOffset = scrollPadding
                    } else if cycleT < pauseTime + travelTime {
                        targetOffset = scrollPadding - (maxScroll * CGFloat((cycleT - pauseTime) / travelTime))
                    } else {
                        targetOffset = scrollPadding - maxScroll
                    }
                } else {
                    let p = step.progress
                    let smoothT = CGFloat(p * p * (3.0 - 2.0 * p))
                    targetOffset = scrollPadding - (maxScroll * smoothT)
                }
            }

            if currentLineText != lastRenderedLyricsText {
                lastWordLeadX = nil
                oldMarqueeOffset = marqueeOffset
                lastRenderedLyricsText = currentLineText
                marqueeOffset = scrollPadding
            } else {
                let effectiveTarget = step.transitionProgress < 0.45 ? scrollPadding : targetOffset
                let smoothSpeed = CGFloat(1.0 - exp(-16.0 * deltaTime))
                marqueeOffset += (effectiveTarget - marqueeOffset) * smoothSpeed
            }

            // Artwork update
            let artKey = "\(track.id)_\(coreEngine.artworkRevision)"
            if cachedAlbumArtTrackId != artKey {
                let shouldCrossfade = (cachedAlbumArtTrackId != nil)
                cachedAlbumArtTrackId = artKey
                if shouldCrossfade {
                    dynamicIslandPopStartTime = CACurrentMediaTime()
                }
                if let directImage = coreEngine.artworkImage {
                    hasRealAlbumArt = true
                    menuBarCanvasView?.setArtwork(
                        directImage,
                        artKey: artKey,
                        isFallbackSymbol: false,
                        isDark: isDark,
                        crossfadePrevious: shouldCrossfade
                    )
                    cachedWaveformTheme = waveformBars > 0 ? ColorExtractor.extractWaveformTheme(from: directImage) : .fallback
                } else {
                    hasRealAlbumArt = false
                    menuBarCanvasView?.setArtwork(
                        idlePlaySymbol,
                        artKey: "fallback_\(isDark ? 1 : 0)",
                        isFallbackSymbol: true,
                        isDark: isDark,
                        crossfadePrevious: false
                    )
                    cachedWaveformTheme = .fallback
                }
            }

            let lyricsWidth: CGFloat = (canvasWidth > 2) ? canvasWidth : 0
            var totalWidth: CGFloat = 0
            var lyricsX: CGFloat = 0
            var vizX: CGFloat = 0
            var artX: CGFloat = 0

            if lyricsWidth > 0 { lyricsX = totalWidth; totalWidth += lyricsWidth }
            if vizWidth > 0 { if totalWidth > 0 { totalWidth += gap }; vizX = totalWidth; totalWidth += vizWidth }
            if artWidth > 0 { if totalWidth > 0 { totalWidth += gap }; artX = totalWidth; totalWidth += artWidth }
            totalWidth = max(24.0, totalWidth)
            let quantizedWidth = ceil(totalWidth / 4.0) * 4.0

            if vizWidth > 0 {
                coreEngine.tickWaveformBars(
                    deltaTime: deltaTime,
                    isTapRunning: audioTap.isRunning,
                    barCount: barCount,
                    outHeights: &barHeights
                )
            } else if !barHeights.isEmpty {
                barHeights.removeAll(keepingCapacity: true)
            }

            let popElapsedRaw = CACurrentMediaTime() - dynamicIslandPopStartTime
            let popElapsed: TimeInterval? = (dynamicIslandPopStartTime > 0 && popElapsedRaw < 0.75) ? popElapsedRaw : nil

            if let item = self.statusItem, abs(item.length - quantizedWidth) > 0.5 {
                item.length = quantizedWidth
            }
            if let canvas = menuBarCanvasView {
                let targetFrame = NSRect(x: 0, y: 0, width: quantizedWidth, height: max(22.0, button.bounds.height))
                if abs(canvas.frame.width - targetFrame.width) > 0.5 || abs(canvas.frame.height - targetFrame.height) > 0.5 {
                    canvas.frame = targetFrame
                }
            }

            menuBarCanvasView?.renderFrame(
                currentLineText: currentLineText,
                textSize: textSize,
                glowPad: glowPad,
                showLyrics: lyricsWidth > 0,
                lyricsX: lyricsX,
                canvasWidth: canvasWidth,
                marqueeOffset: marqueeOffset,
                oldMarqueeOffset: oldMarqueeOffset,
                transitionProgress: CGFloat(step.transitionProgress),
                progress: step.progress,
                wordLeadX: wordLeadX,
                animatedOrbAlpha: CGFloat(step.animatedOrbAlpha),
                isDark: isDark,
                isSparkling: step.isSparklingCandidate,
                sparkleCycleTime: step.sparkleCycleTime,
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
                artScale: CGFloat(step.artScale),
                popElapsed: popElapsed,
                artOpacity: CGFloat(step.artOpacity)
            )

            if panel?.isVisible == true {
                hudContentView?.lyricsView.renderFrame(
                    currentTime: coreEngine.currentTime(),
                    deltaTime: deltaTime,
                    isPlaying: coreEngine.isPlaying
                )
            }

            if !step.needsActiveFrames && popElapsed == nil && !(panel?.isVisible == true && coreEngine.isPlaying) {
                syncMenuBarTimerState()
            }
        } else {
            showIdleButtonFallback()
            if panel?.isVisible == true {
                hudContentView?.lyricsView.renderFrame(currentTime: 0, deltaTime: deltaTime, isPlaying: false)
            }
            if isActiveUpdating {
                stopMenuBarUpdater()
            }
        }
    }
}
