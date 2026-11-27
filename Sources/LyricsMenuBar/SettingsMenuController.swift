import AppKit

// MARK: - Native NSMenu for Settings (Universal Multi-App Support + Full Parity)
@MainActor
final class SettingsMenuController: NSObject {
    static let shared = SettingsMenuController()

    private static var modalPresentationDepth: Int = 0
    static var isPresentingModal: Bool { modalPresentationDepth > 0 }
    static let modalPresentationDidEndNotification = Notification.Name("ModalPresentationDidEnd")

    static func beginModalPresentation() {
        modalPresentationDepth += 1
    }

    static func endModalPresentation() {
        modalPresentationDepth = max(0, modalPresentationDepth - 1)
        if modalPresentationDepth == 0 {
            NotificationCenter.default.post(name: modalPresentationDidEndNotification, object: nil)
        }
    }

    private override init() {
        super.init()
    }

    private func makeMenu(title: String = "") -> NSMenu {
        let m = NSMenu(title: title)
        m.autoenablesItems = false
        return m
    }

    func showMenu(anchoredTo sender: NSView) {
        let ud = UserDefaults.standard
        let showLyrics = ud.object(forKey: AppSettingKey.showLyrics) == nil ? true : ud.bool(forKey: AppSettingKey.showLyrics)
        let showAlbumArt = ud.object(forKey: AppSettingKey.showAlbumArt) == nil ? true : ud.bool(forKey: AppSettingKey.showAlbumArt)
        let lyricsFocusMode = ud.object(forKey: AppSettingKey.lyricsFocusMode) == nil ? true : ud.bool(forKey: AppSettingKey.lyricsFocusMode)
        let lyricsMaxWidth = ud.object(forKey: AppSettingKey.lyricsMaxWidth) == nil ? 200 : ud.integer(forKey: AppSettingKey.lyricsMaxWidth)
        let sourceSelection = MusicIPCBridge.shared.sourceSelection
        let universalEnabled = MusicIPCBridge.shared.universalNowPlayingEnabled
        let isUltraLight = AppPerformance.isUltraLightMode
        let specularEdgeEnabled = ud.object(forKey: AppSettingKey.specularEdgeEnabled) == nil ? !AppPerformance.defaultUltraLightMode : ud.bool(forKey: AppSettingKey.specularEdgeEnabled)
        let hapticIntensity = ud.integer(forKey: AppSettingKey.hapticIntensity)
        let hapticActuatorType = ud.integer(forKey: AppSettingKey.hapticActuatorType)
        let audioFeaturesEnabled = ud.object(forKey: AppSettingKey.audioFeaturesEnabled) == nil ? (AppCapabilities.supportsAudioTap && !AppPerformance.defaultUltraLightMode) : ud.bool(forKey: AppSettingKey.audioFeaturesEnabled)
        let waveformBars = ud.object(forKey: AppSettingKey.waveformBars) == nil ? ((AppPerformance.defaultUltraLightMode || !AppCapabilities.supportsAudioTap) ? 0 : 14) : ud.integer(forKey: AppSettingKey.waveformBars)

        let menu = makeMenu()

        // ── 1. General Submenu ─────────────────────────────────────────────
        let generalItem = NSMenuItem(title: "General", action: nil, keyEquivalent: "")
        let generalMenu = makeMenu(title: "General")

        let lyricsItem = NSMenuItem(title: "Lyrics in Menu Bar", action: #selector(toggleLyrics), keyEquivalent: "")
        lyricsItem.target = self
        lyricsItem.state = showLyrics ? .on : .off
        generalMenu.addItem(lyricsItem)

        let albumItem = NSMenuItem(title: "Album Cover", action: #selector(toggleAlbum), keyEquivalent: "")
        albumItem.target = self
        albumItem.state = showAlbumArt ? .on : .off
        generalMenu.addItem(albumItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        generalMenu.addItem(loginItem)

        generalMenu.addItem(.separator())

        // Dynamic Universal Music Source Submenu
        let sourceItem = NSMenuItem(title: "Music Source", action: nil, keyEquivalent: "")
        let sourceMenu = makeMenu(title: "Music Source")

        let activeLabel = LyricsCoreEngine.shared.currentTrack?.sourceDisplayName
        let autoTitle = activeLabel.map { "Auto (Active: \($0))" } ?? "Auto (Detect Any Player)"
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(setMusicSource(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = "Auto"
        autoItem.state = (sourceSelection == .auto) ? .on : .off
        sourceMenu.addItem(autoItem)

        let universalItem = NSMenuItem(title: "Universal Streaming & Web Players", action: #selector(toggleUniversalNowPlaying), keyEquivalent: "")
        universalItem.target = self
        universalItem.state = universalEnabled ? .on : .off
        sourceMenu.addItem(universalItem)

        let registry = MusicSourceRegistry.shared
        let installed = registry.installedPlayers()
        let appPlayers = installed.filter { $0.category != .browser }
        let browsers = installed.filter { $0.category == .browser }

        if !appPlayers.isEmpty {
            sourceMenu.addItem(.separator())
            for desc in appPlayers {
                let running = registry.isRunning(desc)
                let title = running ? "\(desc.displayName)  ●" : desc.displayName
                let item = NSMenuItem(title: title, action: #selector(setMusicSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = desc.id
                item.state = (sourceSelection == .specific(bundleID: desc.id)) ? .on : .off
                sourceMenu.addItem(item)
            }
        }

        if !browsers.isEmpty {
            sourceMenu.addItem(.separator())
            let browserParent = NSMenuItem(title: "Web Browsers (YouTube Music, Spotify Web, ...)", action: nil, keyEquivalent: "")
            let browserMenu = makeMenu(title: "Web Browsers")
            for desc in browsers {
                let running = registry.isRunning(desc)
                let title = running ? "\(desc.displayName)  ●" : desc.displayName
                let item = NSMenuItem(title: title, action: #selector(setMusicSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = desc.id
                item.state = (sourceSelection == .specific(bundleID: desc.id)) ? .on : .off
                browserMenu.addItem(item)
            }
            browserParent.submenu = browserMenu
            sourceMenu.addItem(browserParent)
        }

        sourceItem.submenu = sourceMenu
        generalMenu.addItem(sourceItem)
        generalItem.submenu = generalMenu
        menu.addItem(generalItem)

        // ── 2. Lyrics & Animation Submenu ──────────────────────────────────
        let lyricsSectionItem = NSMenuItem(title: "Lyrics & Animation", action: nil, keyEquivalent: "")
        let lyricsSectionMenu = makeMenu(title: "Lyrics & Animation")

        let focusItem = NSMenuItem(title: "Lyrics Focus Mode", action: #selector(toggleFocusMode), keyEquivalent: "")
        focusItem.target = self
        focusItem.state = lyricsFocusMode ? .on : .off
        lyricsSectionMenu.addItem(focusItem)

        let widthItem = NSMenuItem(title: "Lyrics Width", action: nil, keyEquivalent: "")
        let widthMenu = makeMenu(title: "Lyrics Width")
        var widths = [0, 50, 100, 150, 200, 250, 260, 300]
        if !widths.contains(lyricsMaxWidth) {
            widths.append(lyricsMaxWidth)
            widths.sort()
        }
        for w in widths {
            let title = w == 0 ? "Off" : "\(w) px"
            let item = NSMenuItem(title: title, action: #selector(setWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = w
            item.state = lyricsMaxWidth == w ? .on : .off
            widthMenu.addItem(item)
        }
        widthMenu.addItem(.separator())
        let wCustomItem = NSMenuItem(title: "Custom...", action: #selector(promptCustomWidth), keyEquivalent: "")
        wCustomItem.target = self
        widthMenu.addItem(wCustomItem)
        widthItem.submenu = widthMenu
        lyricsSectionMenu.addItem(widthItem)
        lyricsSectionItem.submenu = lyricsSectionMenu
        menu.addItem(lyricsSectionItem)

        // ── 3. Appearance & Performance Submenu ────────────────────────────
        let appearanceItem = NSMenuItem(title: "Appearance & Performance", action: nil, keyEquivalent: "")
        let appearanceMenu = makeMenu(title: "Appearance & Performance")

        let ultraLightItem = NSMenuItem(title: "Reduce Glass & Blur Effects (60 FPS Lightweight)", action: #selector(toggleUltraLightMode), keyEquivalent: "")
        ultraLightItem.target = self
        ultraLightItem.state = isUltraLight ? .on : .off
        appearanceMenu.addItem(ultraLightItem)

        let specularItem = NSMenuItem(title: "Specular Edge Highlight", action: #selector(toggleSpecularEdge), keyEquivalent: "")
        specularItem.target = self
        specularItem.isEnabled = !isUltraLight
        specularItem.state = (!isUltraLight && specularEdgeEnabled) ? .on : .off
        appearanceMenu.addItem(specularItem)

        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        // ── 4. Haptics Submenu ─────────────────────────────────────────────
        if !AppCapabilities.supportsAudioTap {
            let hapticsItem = NSMenuItem(title: "Haptics (Requires macOS 14.2+)", action: nil, keyEquivalent: "")
            hapticsItem.isEnabled = false
            menu.addItem(hapticsItem)
        } else {
            let hapticsItem = NSMenuItem(title: "Haptics", action: nil, keyEquivalent: "")
            let hapticsMenu = makeMenu(title: "Haptics")

            let intensityItem = NSMenuItem(title: "Intensity", action: nil, keyEquivalent: "")
            let intensityMenu = makeMenu(title: "Intensity")
            for (i, mode) in ["Off", "Light", "Medium", "Firm"].enumerated() {
                let item = NSMenuItem(title: mode, action: #selector(setHaptic(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.state = hapticIntensity == i ? .on : .off
                intensityMenu.addItem(item)
            }
            intensityItem.submenu = intensityMenu
            hapticsMenu.addItem(intensityItem)

            hapticsMenu.addItem(.separator())
            let feelItem = NSMenuItem(title: "Haptic Feel", action: nil, keyEquivalent: "")
            let feelMenu = makeMenu(title: "Haptic Feel")
            let types: [(tag: Int, desc: String)] = [
                (0, "Auto (kick=6, beat=4)"),
                (1, "1 - Very light tap"),
                (2, "2 - Light-medium click"),
                (3, "3 - Standard click"),
                (4, "4 - Sharp crisp (Pacinian)"),
                (5, "5 - Medium-heavy"),
                (6, "6 - Deep sub-bass thump")
            ]
            for t in types {
                let item = NSMenuItem(title: t.desc, action: #selector(setHapticType(_:)), keyEquivalent: "")
                item.target = self
                item.tag = t.tag
                item.state = hapticActuatorType == t.tag ? .on : .off
                feelMenu.addItem(item)
            }
            feelMenu.addItem(.separator())
            let testItem = NSMenuItem(title: "▶ Test All Types (0.4s apart)", action: #selector(testAllHapticTypes), keyEquivalent: "")
            testItem.target = self
            feelMenu.addItem(testItem)
            feelItem.submenu = feelMenu
            hapticsMenu.addItem(feelItem)

            hapticsItem.submenu = hapticsMenu
            menu.addItem(hapticsItem)
        }

        // ── 5. Audio Submenu ───────────────────────────────────────────────
        let audioSectionItem = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        let audioSectionMenu = makeMenu(title: "Audio")

        let audioItem: NSMenuItem
        if !AppCapabilities.supportsAudioTap {
            audioItem = NSMenuItem(title: "Audio Visualizer Tap (Requires macOS 14.2+)", action: nil, keyEquivalent: "")
            audioItem.isEnabled = false
        } else {
            audioItem = NSMenuItem(title: "Audio Visualizer (Tap)", action: #selector(toggleAudioFeatures), keyEquivalent: "")
            audioItem.target = self
            audioItem.state = audioFeaturesEnabled ? .on : .off
        }
        audioSectionMenu.addItem(audioItem)

        let waveItem = NSMenuItem(title: "Waveform Bars", action: nil, keyEquivalent: "")
        let waveMenu = makeMenu(title: "Waveform Bars")
        var wModes = [0, 6, 10, 14, 24, 32, 48, 128]
        if !wModes.contains(waveformBars) {
            wModes.append(waveformBars)
            wModes.sort()
        }
        for bars in wModes {
            let title = bars == 0 ? "Off" : "\(bars) Bars"
            let item = NSMenuItem(title: title, action: #selector(setWaveform(_:)), keyEquivalent: "")
            item.target = self
            item.tag = bars
            item.state = waveformBars == bars ? .on : .off
            waveMenu.addItem(item)
        }
        waveMenu.addItem(.separator())
        let waveCustomItem = NSMenuItem(title: "Custom...", action: #selector(promptCustomWaveform), keyEquivalent: "")
        waveCustomItem.target = self
        waveMenu.addItem(waveCustomItem)
        waveItem.submenu = waveMenu
        audioSectionMenu.addItem(waveItem)

        audioSectionItem.submenu = audioSectionMenu
        menu.addItem(audioSectionItem)

        menu.addItem(.separator())

        let updateTitle = LyricsCoreEngine.shared.hasUpdate ? "Check for Updates... (Update Available)" : "Check for Updates..."
        let updateItem = NSMenuItem(title: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let aboutItem = NSMenuItem(title: "About & License...", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LyricsMenuBar", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        let pt = NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 5)
        Self.beginModalPresentation()
        defer { Self.endModalPresentation() }
        menu.popUp(positioning: nil, at: pt, in: sender)
    }

    @objc private func checkForUpdates() {
        LyricsCoreEngine.shared.checkForUpdates(manual: true)
    }

    @objc private func setMusicSource(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: AppSettingKey.musicSourceMode)
        if key == "Auto" {
            MusicIPCBridge.shared.pollActivePlayer()
        } else {
            NotificationCenter.default.post(
                name: Notification.Name("ActiveMusicSourceChanged"),
                object: nil,
                userInfo: ["bundleID": key, "sourceID": key]
            )
            MusicIPCBridge.shared.clearAutomationDenialAndPoll(for: key)
        }
    }

    @objc private func toggleUniversalNowPlaying() {
        let newVal = !MusicIPCBridge.shared.universalNowPlayingEnabled
        UserDefaults.standard.set(newVal, forKey: AppSettingKey.universalNowPlayingEnabled)
        MusicIPCBridge.shared.pollActivePlayer()
    }

    @objc private func showAbout() {
        Self.beginModalPresentation()
        defer { Self.endModalPresentation() }
        let eng = LyricsCoreEngine.shared
        let alert = NSAlert()
        let modeLabel = AppPerformance.isUltraLightMode ? "60 FPS Lightweight" : "Standard Glass"
        alert.messageText = "Lyrics Menu Bar \(eng.currentVersion) (Build \(eng.currentBuild))"
        alert.informativeText = "Rust Core Engine + Pure AppKit 60 FPS HUD (\(modeLabel))\nUniversal Streaming Support: Spotify, Apple Music, YouTube Music, TIDAL, Deezer, Qobuz, SoundCloud, Cider, VLC, Swinsian, VOX & Web Players.\n\nLicensed under the MIT License\nCopyright © 2026 Puwadon and Contributors\n\nOpen Source & Free."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleUltraLightMode() {
        let newVal = !AppPerformance.isUltraLightMode
        UserDefaults.standard.set(newVal, forKey: AppSettingKey.ultraLightMode)
        UserDefaults.standard.set(!newVal, forKey: AppSettingKey.specularEdgeEnabled)
        if newVal && !AppCapabilities.supportsAudioTap {
            UserDefaults.standard.set(0, forKey: AppSettingKey.waveformBars)
        }
        NotificationCenter.default.post(name: Notification.Name("UltraLightModeChanged"), object: nil)
    }

    @objc private func toggleFocusMode() {
        let ud = UserDefaults.standard
        let current = ud.object(forKey: AppSettingKey.lyricsFocusMode) != nil ? ud.bool(forKey: AppSettingKey.lyricsFocusMode) : true
        ud.set(!current, forKey: AppSettingKey.lyricsFocusMode)
    }

    @objc private func toggleSpecularEdge() {
        let ud = UserDefaults.standard
        let current = ud.object(forKey: AppSettingKey.specularEdgeEnabled) != nil ? ud.bool(forKey: AppSettingKey.specularEdgeEnabled) : !AppPerformance.defaultUltraLightMode
        ud.set(!current, forKey: AppSettingKey.specularEdgeEnabled)
        NotificationCenter.default.post(name: Notification.Name("UltraLightModeChanged"), object: nil)
    }

    @objc private func toggleLyrics() {
        let ud = UserDefaults.standard
        let current = ud.object(forKey: AppSettingKey.showLyrics) != nil ? ud.bool(forKey: AppSettingKey.showLyrics) : true
        ud.set(!current, forKey: AppSettingKey.showLyrics)
    }

    @objc private func toggleAlbum() {
        let ud = UserDefaults.standard
        let current = ud.object(forKey: AppSettingKey.showAlbumArt) != nil ? ud.bool(forKey: AppSettingKey.showAlbumArt) : true
        ud.set(!current, forKey: AppSettingKey.showAlbumArt)
    }

    @objc private func toggleAudioFeatures() {
        let ud = UserDefaults.standard
        let current = ud.object(forKey: AppSettingKey.audioFeaturesEnabled) != nil ? ud.bool(forKey: AppSettingKey.audioFeaturesEnabled) : true
        let newVal = !current
        ud.set(newVal, forKey: AppSettingKey.audioFeaturesEnabled)
        NotificationCenter.default.post(name: Notification.Name(newVal ? "AudioFeaturesEnabled" : "AudioFeaturesDisabled"), object: nil)
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLoginManager.isEnabled.toggle()
    }

    @objc private func setWidth(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: AppSettingKey.lyricsMaxWidth)
    }

    @objc private func setHaptic(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: AppSettingKey.hapticIntensity)
        // Auto-enable Audio Tap when turning on Haptics so beat detection works immediately
        if sender.tag > 0 && AppCapabilities.supportsAudioTap {
            let ud = UserDefaults.standard
            if !ud.bool(forKey: AppSettingKey.audioFeaturesEnabled) {
                ud.set(true, forKey: AppSettingKey.audioFeaturesEnabled)
                NotificationCenter.default.post(name: Notification.Name("AudioFeaturesEnabled"), object: nil)
            }
        }
    }

    @objc private func setWaveform(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: AppSettingKey.waveformBars)
        if sender.tag > 0 && AppCapabilities.supportsAudioTap {
            let ud = UserDefaults.standard
            if !ud.bool(forKey: AppSettingKey.audioFeaturesEnabled) {
                ud.set(true, forKey: AppSettingKey.audioFeaturesEnabled)
                NotificationCenter.default.post(name: Notification.Name("AudioFeaturesEnabled"), object: nil)
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func setHapticType(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: AppSettingKey.hapticActuatorType)
        let t: Int32 = sender.tag == 0 ? 4 : Int32(sender.tag)
        LyricsCoreEngine.shared.setHapticActuatorType(Int32(sender.tag))
        LyricsCoreEngine.shared.testHapticActuatorType(t)
    }

    @objc private func testAllHapticTypes() {
        for i in 0..<6 {
            let t = Int32(i + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) {
                LyricsCoreEngine.shared.testHapticActuatorType(t)
            }
        }
    }

    @objc private func promptCustomWidth() {
        Self.beginModalPresentation()
        defer { Self.endModalPresentation() }
        let current = UserDefaults.standard.object(forKey: AppSettingKey.lyricsMaxWidth) == nil ? 200 : UserDefaults.standard.integer(forKey: AppSettingKey.lyricsMaxWidth)
        let alert = NSAlert()
        alert.messageText = "Custom Lyrics Width"
        alert.informativeText = "Enter max width in pixels (e.g., 450). Maximum allowed is 1000 px to prevent Menu Bar overflow:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = String(current)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let val = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            UserDefaults.standard.set(min(max(0, val), 1000), forKey: AppSettingKey.lyricsMaxWidth)
        }
    }

    @objc private func promptCustomWaveform() {
        Self.beginModalPresentation()
        defer { Self.endModalPresentation() }
        let current = UserDefaults.standard.object(forKey: AppSettingKey.waveformBars) == nil ? 14 : UserDefaults.standard.integer(forKey: AppSettingKey.waveformBars)
        let alert = NSAlert()
        alert.messageText = "Custom Waveform Bars"
        alert.informativeText = "Enter number of bars. Maximum allowed is 128 to prevent Menu Bar overflow:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = String(current)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let val = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let clamped = min(max(0, val), 128)
            UserDefaults.standard.set(clamped, forKey: AppSettingKey.waveformBars)
            if clamped > 0 && AppCapabilities.supportsAudioTap {
                let ud = UserDefaults.standard
                if !ud.bool(forKey: AppSettingKey.audioFeaturesEnabled) {
                    ud.set(true, forKey: AppSettingKey.audioFeaturesEnabled)
                    NotificationCenter.default.post(name: Notification.Name("AudioFeaturesEnabled"), object: nil)
                }
            }
        }
    }
}
