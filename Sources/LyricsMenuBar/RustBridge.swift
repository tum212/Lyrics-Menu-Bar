import AppKit
import CLyricsCore
import Foundation
import ImageIO

// MARK: - Domain Models

public enum MusicSourceMode: Int32, CaseIterable, Sendable {
    case auto = 0
    case spotify = 1
    case appleMusic = 2

    public var defaultsValue: String {
        switch self {
        case .auto: return "Auto"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }

    public init(defaultsValue: String) {
        switch defaultsValue {
        case "Spotify": self = .spotify
        case "Apple Music": self = .appleMusic
        default: self = .auto
        }
    }
}

public struct TrackModel: Equatable, Sendable {
    public var id: String
    public var name: String
    public var artist: String
    public var album: String
    public var artworkURL: String?
    public var artworkData: Data?
    public var duration: Double
    public var source: MusicSourceMode
}

public struct LyricWordModel: Decodable, Equatable, Sendable {
    public let id: UInt64
    public let text: String
    public let startTime: Double
    public let endTime: Double
    public let index: Int

    enum CodingKeys: String, CodingKey {
        case id, text, index
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

public struct LyricLineModel: Decodable, Equatable, Sendable {
    public let id: UInt64
    public let time: Double
    public let endTime: Double
    public let text: String
    public let words: [LyricWordModel]
    public let isBackgroundVocal: Bool

    enum CodingKeys: String, CodingKey {
        case id, time, text, words
        case endTime = "end_time"
        case isBackgroundVocal = "is_background_vocal"
    }
}

public struct WaveformThemeModel: Sendable {
    public var topColor: NSColor
    public var bottomColor: NSColor
    public var glowColor: NSColor
    public var accentColor: NSColor

    public static let fallback = WaveformThemeModel(
        topColor: NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.1, alpha: 1.0),
        bottomColor: NSColor(calibratedRed: 1.0, green: 0.50, blue: 0.0, alpha: 1.0),
        glowColor: NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.1, alpha: 0.65),
        accentColor: NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.3, alpha: 1.0)
    )
}

public enum UpdateStateModel: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, releaseNotes: String, downloadUrl: String)
    case downloading(progress: Double)
    case installing
    case failed(error: String)
}

public struct MenuBarStepResult {
    public let hasTrack: Bool
    public let text: String
    public let lineId: UInt64
    public let progress: Double
    public let isIntro: Bool
    public let isUnsynced: Bool
    public let isInterlude: Bool
    public let peekedAhead: Bool
    public let activeWordIndex: Int
    public let activeWordProgress: Double
    public let activeWordBeforeStart: Bool
    public let activeWordAfterEnd: Bool
    public let lineChanged: Bool
    public let transitionProgress: Double
    public let animatedOrbAlpha: Double
    public let artScale: Double
    public let artOpacity: Double
    public let needsActiveFrames: Bool
    public let isSparklingCandidate: Bool
    public let sparkleCycleTime: Double
}

private struct RustUpdateCheckOutcome: Decodable {
    let updateAvailable: Bool
    let version: String
    let releaseNotes: String
    let downloadUrl: String
    let endpoints: RustEndpoints?

    enum CodingKeys: String, CodingKey {
        case version
        case updateAvailable = "update_available"
        case releaseNotes = "release_notes"
        case downloadUrl = "download_url"
        case endpoints
    }
}

private struct RustEndpoints: Decodable {
    let lrclibSearch: String
    let lrclibGet: String
    let lyricsOvh: String

    enum CodingKeys: String, CodingKey {
        case lrclibSearch = "lrclib_search"
        case lrclibGet = "lrclib_get"
        case lyricsOvh = "lyrics_ovh"
    }
}

// MARK: - Artwork Cache & Fast Color Extraction

@MainActor
public final class ArtworkCache {
    public static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        if AppPerformance.isUltraLightMode {
            cache.countLimit = 30
            cache.totalCostLimit = 12 * 1024 * 1024
        } else {
            cache.countLimit = 100
            cache.totalCostLimit = 30 * 1024 * 1024
        }
    }

    public func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    public func setImage(_ image: NSImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    public static func cacheKey(for track: TrackModel) -> String {
        let nameKey = track.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let artistKey = track.artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(track.source.defaultsValue)|\(nameKey)|\(artistKey)"
    }

    public static func normalizeKey(name: String, artist: String) -> String {
        let nameKey = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let artistKey = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(nameKey)|\(artistKey)"
    }

    public func storeImage(_ image: NSImage, for track: TrackModel) {
        setImage(image, forKey: track.id)
        setImage(image, forKey: Self.cacheKey(for: track))
        setImage(image, forKey: Self.normalizeKey(name: track.name, artist: track.artist))
    }

    public func findImage(for track: TrackModel) -> NSImage? {
        image(forKey: track.id)
            ?? image(forKey: Self.cacheKey(for: track))
            ?? image(forKey: Self.normalizeKey(name: track.name, artist: track.artist))
    }
}

public enum ColorExtractor {
    public static func extractWaveformTheme(from image: NSImage) -> WaveformThemeModel {
        let w = 48
        let h = 48
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &rgba,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return .fallback
        }

        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        let res = rgba.withUnsafeBufferPointer { buf in
            lyrics_core_extract_waveform_theme_rgba(buf.baseAddress, w, h)
        }

        func toNS(_ c: CFfiRgbaColor) -> NSColor {
            NSColor(calibratedRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
        }
        return WaveformThemeModel(
            topColor: toNS(res.top),
            bottomColor: toNS(res.bottom),
            glowColor: toNS(res.glow),
            accentColor: toNS(res.accent)
        )
    }

    public static func decodeCompactImage(from data: Data, maxDimension: CGFloat) -> NSImage? {
        guard !data.isEmpty else { return nil }
        if let src = CGImageSourceCreateWithData(data as CFData, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return NSImage(data: data)
    }
}

// MARK: - Nonisolated C ABI Callbacks (Safe to invoke from Rust threads under Swift 6)

private func onRustLyricsReady(_ ctx: UInt, _ requestId: UInt64) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            LyricsCoreEngine.shared.syncLyricsFromRust()
        }
    }
}

private func onRustUpdateChecked(_ ctx: UInt, _ outcomePtr: UnsafeMutablePointer<CChar>?) {
    var json = "{}"
    if let p = outcomePtr {
        json = String(cString: p)
        lyrics_core_free_string(p)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            LyricsCoreEngine.shared.handleUpdateCheckJSON(json)
        }
    }
}

private func onRustDownloadProgress(_ ctx: UInt, _ progress: Double) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            LyricsCoreEngine.shared.handleDownloadProgress(progress)
        }
    }
}

private func onRustDownloadComplete(_ ctx: UInt, _ success: Bool, _ errPtr: UnsafeMutablePointer<CChar>?) {
    var errStr = ""
    if let e = errPtr {
        errStr = String(cString: e)
        lyrics_core_free_string(e)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            LyricsCoreEngine.shared.handleDownloadComplete(success: success, error: errStr)
        }
    }
}

// MARK: - Rust Core Facade

@MainActor
public final class LyricsCoreEngine {
    public static let shared = LyricsCoreEngine()

    public let coreHandle: OpaquePointer
    public let audioHandle: OpaquePointer
    public let hapticsHandle: OpaquePointer

    // State
    public private(set) var currentTrack: TrackModel?
    public private(set) var isPlaying: Bool = false
    public private(set) var activeSource: MusicSourceMode = .spotify
    public private(set) var lyrics: [LyricLineModel] = []
    public private(set) var isLyricsLoading: Bool = false

    public private(set) var artworkImage: NSImage?
    public private(set) var artworkRevision: Int = 0
    public var isPanelVisible: Bool = false

    public private(set) var updateState: UpdateStateModel = .idle
    public private(set) var showUpdateModal: Bool = false
    public var hasUpdate: Bool {
        if case .updateAvailable = updateState { return true }
        return false
    }

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
    }
    public var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    // Notifications for lightweight AppKit observers
    public static let trackDidChangeNotification = Notification.Name("RustCoreTrackDidChange")
    public static let lyricsDidChangeNotification = Notification.Name("RustCoreLyricsDidChange")
    public static let artworkDidChangeNotification = Notification.Name("RustCoreArtworkDidChange")
    public static let playStateDidChangeNotification = Notification.Name("RustCorePlayStateDidChange")
    public static let playbackDidSeekNotification = Notification.Name("RustCorePlaybackDidSeek")
    public static let updateStateDidChangeNotification = Notification.Name("RustCoreUpdateStateDidChange")

    private var artworkGeneration: Int = 0
    private var artworkTask: Task<Void, Never>?
    private var artworkRetryCount: Int = 0
    private var nextArtworkRetryDate: Date = .distantPast
    private let retryIntervals: [TimeInterval] = [0.2, 0.5, 1.2, 2.0]
    private var isManualUpdateCheck = false
    private let targetDmgPath = "/tmp/LyricsMenuBarUpdate.dmg"

    private init() {
        self.coreHandle = lyrics_core_create()!
        self.audioHandle = lyrics_core_audio_create()!
        self.hapticsHandle = lyrics_core_haptics_create()!

        syncSavedEndpoints()

        let savedHapticType = Int32(UserDefaults.standard.integer(forKey: AppSettingKey.hapticActuatorType))
        lyrics_core_haptics_set_actuator_type(hapticsHandle, savedHapticType)
        let latencyOffset = UserDefaults.standard.double(forKey: "hapticLatencyOffset")
        lyrics_core_haptics_set_latency_offset(hapticsHandle, latencyOffset)

        // Auto-check updates 3 seconds after launch
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.checkForUpdates(manual: false)
        }
    }

    private func syncSavedEndpoints() {
        let ud = UserDefaults.standard
        let search = ud.string(forKey: "config_lrclib_search") ?? ""
        let get = ud.string(forKey: "config_lrclib_get") ?? ""
        let ovh = ud.string(forKey: "config_lyrics_ovh") ?? ""
        search.withCString { sPtr in
            get.withCString { gPtr in
                ovh.withCString { oPtr in
                    lyrics_core_lyrics_set_endpoints(coreHandle, sPtr, gPtr, oPtr)
                }
            }
        }
    }

    public func currentTime() -> Double {
        lyrics_core_playback_current_time(coreHandle, ProcessInfo.processInfo.systemUptime)
    }

    public func seekLocal(to time: Double) {
        lyrics_core_playback_seek_local(coreHandle, max(0, time), ProcessInfo.processInfo.systemUptime)
        NotificationCenter.default.post(name: Self.playbackDidSeekNotification, object: self)
    }

    public func togglePlayStateLocal() {
        isPlaying.toggle()
        lyrics_core_playback_set_playing_local(coreHandle, isPlaying, ProcessInfo.processInfo.systemUptime)
        NotificationCenter.default.post(name: Self.playStateDidChangeNotification, object: self)
    }

    public func updatePlaybackState(track: TrackModel, position: Double, isPlaying: Bool, source: MusicSourceMode) {
        let nowMono = ProcessInfo.processInfo.systemUptime
        let nowUnix = Date().timeIntervalSince1970

        let delta: CFfiPlaybackDelta = track.id.withCString { idPtr in
            track.name.withCString { namePtr in
                track.artist.withCString { artPtr in
                    track.album.withCString { albPtr in
                        (track.artworkURL ?? "").withCString { urlPtr in
                            lyrics_core_playback_update(
                                coreHandle,
                                idPtr,
                                namePtr,
                                artPtr,
                                albPtr,
                                urlPtr,
                                track.duration,
                                position,
                                isPlaying,
                                source.rawValue,
                                nowMono,
                                nowUnix
                            )
                        }
                    }
                }
            }
        }

        if delta.source_changed {
            self.activeSource = source
            let bundleID = (source == .appleMusic) ? "com.apple.Music" : "com.spotify.client"
            NotificationCenter.default.post(
                name: Notification.Name("ActiveMusicSourceChanged"),
                object: nil,
                userInfo: ["bundleID": bundleID]
            )
        }

        var updatedTrack = track
        if !delta.track_changed {
            if updatedTrack.artworkData == nil {
                updatedTrack.artworkData = self.currentTrack?.artworkData
            }
            if updatedTrack.artworkURL == nil {
                updatedTrack.artworkURL = self.currentTrack?.artworkURL
            }
        }
        self.currentTrack = updatedTrack

        if delta.play_state_changed {
            self.isPlaying = isPlaying
            NotificationCenter.default.post(name: Self.playStateDidChangeNotification, object: self)
        }

        let shouldRetryArtwork = (self.artworkImage == nil
            && self.artworkRetryCount < self.retryIntervals.count
            && Date() >= self.nextArtworkRetryDate)

        if delta.track_changed {
            if let cached = ArtworkCache.shared.findImage(for: updatedTrack) {
                ArtworkCache.shared.storeImage(cached, for: updatedTrack)
                self.artworkImage = cached
            } else {
                self.artworkImage = nil
            }
            self.artworkRevision += 1
            self.artworkRetryCount = 0
            self.nextArtworkRetryDate = .distantPast
            self.loadArtwork(for: updatedTrack)
            self.fetchLyrics(for: updatedTrack)
            NotificationCenter.default.post(name: Self.trackDidChangeNotification, object: self)
        } else if delta.artwork_url_changed || shouldRetryArtwork {
            self.loadArtwork(for: updatedTrack)
        }
    }

    public func handleStopped(source: MusicSourceMode, threshold: Int32, isNotRunning: Bool) {
        if lyrics_core_playback_mark_stopped(coreHandle, source.rawValue, threshold, isNotRunning) {
            self.currentTrack = nil
            self.isPlaying = false
            self.lyrics = []
            self.isLyricsLoading = false
            lyrics_core_lyrics_clear(coreHandle)
            self.artworkTask?.cancel()
            self.artworkGeneration += 1
            self.artworkImage = nil
            self.artworkRevision += 1
            self.artworkRetryCount = 0
            self.nextArtworkRetryDate = .distantPast
            NotificationCenter.default.post(name: Self.lyricsDidChangeNotification, object: self)
            NotificationCenter.default.post(name: Self.playStateDidChangeNotification, object: self)
            NotificationCenter.default.post(name: Self.trackDidChangeNotification, object: self)
        }
    }

    public func setSpotifyArtworkURLIfMissing(_ urlString: String, expectedTrackName: String) {
        guard let cur = currentTrack, cur.name == expectedTrackName else { return }
        if cur.artworkURL == nil || artworkImage == nil {
            self.currentTrack?.artworkURL = urlString
            self.loadArtwork(for: self.currentTrack!)
        }
    }

    // MARK: - Lyrics Fetch via Rust

    public func fetchLyrics(for track: TrackModel) {
        guard !track.name.isEmpty, !track.artist.isEmpty else {
            self.lyrics = []
            self.isLyricsLoading = false
            NotificationCenter.default.post(name: Self.lyricsDidChangeNotification, object: self)
            return
        }

        let cacheHit = track.name.withCString { tPtr in
            track.artist.withCString { aPtr in
                track.album.withCString { alPtr in
                    lyrics_core_lyrics_fetch(
                        coreHandle,
                        tPtr,
                        aPtr,
                        alPtr,
                        0,
                        onRustLyricsReady
                    )
                }
            }
        }

        if cacheHit {
            syncLyricsFromRust()
        } else {
            self.isLyricsLoading = lyrics_core_lyrics_is_loading(coreHandle)
            if self.isLyricsLoading {
                self.lyrics = []
                NotificationCenter.default.post(name: Self.lyricsDidChangeNotification, object: self)
            }
        }
    }

    fileprivate func syncLyricsFromRust() {
        self.isLyricsLoading = lyrics_core_lyrics_is_loading(coreHandle)
        guard let jsonPtr = lyrics_core_lyrics_get_json(coreHandle) else { return }
        defer { lyrics_core_free_string(jsonPtr) }
        let jsonStr = String(cString: jsonPtr)
        if let data = jsonStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([LyricLineModel].self, from: data) {
            self.lyrics = decoded
        } else {
            self.lyrics = []
        }
        NotificationCenter.default.post(name: Self.lyricsDidChangeNotification, object: self)
    }

    // MARK: - Artwork Loading via Rust Transport + CGImageSource Compact Decode

    private func loadArtwork(for track: TrackModel) {
        if let cached = ArtworkCache.shared.findImage(for: track) {
            self.artworkImage = cached
            self.artworkRevision += 1
            self.artworkRetryCount = 0
            self.nextArtworkRetryDate = .distantPast
            NotificationCenter.default.post(name: Self.artworkDidChangeNotification, object: self)
            return
        }

        artworkGeneration += 1
        let myGen = artworkGeneration
        artworkTask?.cancel()

        if self.currentTrack?.name != track.name {
            self.artworkImage = nil
        }

        artworkTask = Task { [weak self] in
            guard let self = self else { return }
            let isUltraLight = AppPerformance.isUltraLightMode
            let maxDim: CGFloat = isUltraLight ? 240 : 300

            let rawData: Data? = await Task.detached(priority: .userInitiated) {
                if track.source == .appleMusic {
                    let result = MusicIPCBridge.fetchAppleMusicArtworkData(expectedID: track.id)
                    if let data = result.data {
                        return data
                    }
                } else if let rawURL = track.artworkURL {
                    let sanitizedPtr = rawURL.withCString { lyrics_core_sanitize_artwork_url($0) }
                    if let sPtr = sanitizedPtr {
                        let urlStr = String(cString: sPtr)
                        lyrics_core_free_string(sPtr)
                        let buf = urlStr.withCString { lyrics_core_download_bytes($0, 8) }
                        if let ptr = buf.data, buf.len > 0 {
                            let data = Data(bytes: ptr, count: buf.len)
                            lyrics_core_free_bytes(buf)
                            return data
                        }
                    }
                }

                if !track.name.isEmpty {
                    let buf = track.name.withCString { tPtr in
                        track.artist.withCString { aPtr in
                            lyrics_core_fetch_itunes_artwork(tPtr, aPtr)
                        }
                    }
                    if let ptr = buf.data, buf.len > 0 {
                        let data = Data(bytes: ptr, count: buf.len)
                        lyrics_core_free_bytes(buf)
                        return data
                    }
                }
                return nil
            }.value

            guard !Task.isCancelled, self.artworkGeneration == myGen else { return }
            guard let cur = self.currentTrack, cur.name == track.name else { return }
            let loadedImage = rawData.flatMap { ColorExtractor.decodeCompactImage(from: $0, maxDimension: maxDim) }

            if let img = loadedImage {
                ArtworkCache.shared.storeImage(img, for: track)
                self.artworkImage = img
                self.artworkRevision += 1
                self.artworkRetryCount = 0
                self.nextArtworkRetryDate = .distantPast
            } else {
                if self.artworkRetryCount < self.retryIntervals.count {
                    self.nextArtworkRetryDate = Date().addingTimeInterval(self.retryIntervals[self.artworkRetryCount])
                    self.artworkRetryCount += 1
                }
                self.artworkRevision += 1
            }
            NotificationCenter.default.post(name: Self.artworkDidChangeNotification, object: self)
        }
    }

    // MARK: - 60 FPS Menu Bar Stepper & HUD Active Index

    public func stepMenuBarFrame(deltaTime: Double, isUltraLight: Bool) -> MenuBarStepResult {
        let nowMono = ProcessInfo.processInfo.systemUptime
        let nowUnix = Date().timeIntervalSince1970
        let frame = lyrics_core_menubar_step(coreHandle, deltaTime, nowMono, nowUnix, isUltraLight)
        var lineText = ""
        if let ptr = frame.text_ptr {
            lineText = String(cString: ptr)
            lyrics_core_free_string(ptr)
        }
        return MenuBarStepResult(
            hasTrack: frame.has_track,
            text: lineText,
            lineId: frame.line_id,
            progress: frame.progress,
            isIntro: frame.is_intro,
            isUnsynced: frame.is_unsynced,
            isInterlude: frame.is_interlude,
            peekedAhead: frame.peeked_ahead,
            activeWordIndex: Int(frame.active_word_index),
            activeWordProgress: frame.active_word_progress,
            activeWordBeforeStart: frame.active_word_before_start,
            activeWordAfterEnd: frame.active_word_after_end,
            lineChanged: frame.line_changed,
            transitionProgress: frame.transition_progress,
            animatedOrbAlpha: frame.animated_orb_alpha,
            artScale: frame.art_scale,
            artOpacity: frame.art_opacity,
            needsActiveFrames: frame.needs_active_frames,
            isSparklingCandidate: frame.is_sparkling_candidate,
            sparkleCycleTime: frame.sparkle_cycle_time
        )
    }

    public func resolveHUDActiveIndex() -> (index: Int, isUnsynced: Bool) {
        var unsynced = false
        let idx = lyrics_core_playback_hud_active_index(
            coreHandle,
            ProcessInfo.processInfo.systemUptime,
            &unsynced
        )
        return (Int(idx), unsynced)
    }

    // MARK: - Audio & Haptics Bridge

    public func updateWaveformBandCount(_ count: Int) {
        lyrics_core_audio_update_band_count(audioHandle, Int32(count))
    }

    public func tickWaveformBars(
        deltaTime: Double,
        isTapRunning: Bool,
        barCount: Int,
        outHeights: inout [CGFloat]
    ) {
        guard barCount > 0 else {
            outHeights.removeAll(keepingCapacity: true)
            return
        }
        var floatBuf = [Float](repeating: 2.5, count: barCount)
        let n = floatBuf.withUnsafeMutableBufferPointer { ptr in
            lyrics_core_audio_tick_bars(
                audioHandle,
                deltaTime,
                Date().timeIntervalSince1970,
                isPlaying,
                isTapRunning,
                barCount,
                ptr.baseAddress,
                barCount
            )
        }
        if outHeights.count != n {
            outHeights = Array(repeating: 2.5, count: n)
        }
        for i in 0..<n {
            outHeights[i] = CGFloat(floatBuf[i])
        }
    }

    public func setHapticActuatorType(_ type: Int32) {
        lyrics_core_haptics_set_actuator_type(hapticsHandle, type)
    }

    public func testHapticActuatorType(_ type: Int32) {
        lyrics_core_haptics_test_type(hapticsHandle, type)
    }

    // MARK: - Remote Config & OTA Updater via Rust

    public func checkForUpdates(manual: Bool) {
        self.isManualUpdateCheck = manual
        self.updateState = .checking
        NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)

        currentVersion.withCString { verPtr in
            lyrics_core_check_updates_async(
                verPtr,
                Int32(currentBuild),
                0,
                onRustUpdateChecked
            )
        }
    }

    fileprivate func handleDownloadProgress(_ progress: Double) {
        if case .downloading = updateState {
            updateState = .downloading(progress: progress)
            NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)
        }
    }

    fileprivate func handleDownloadComplete(success: Bool, error errStr: String) {
        if success {
            installDownloadedUpdate()
        } else if errStr == "Cancelled" {
            updateState = .idle
            showUpdateModal = false
        } else {
            updateState = .failed(error: errStr.isEmpty ? "Download failed" : errStr)
        }
        NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)
    }

    fileprivate func handleUpdateCheckJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let outcome = try? JSONDecoder().decode(RustUpdateCheckOutcome.self, from: data) else {
            self.updateState = .upToDate
            NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)
            return
        }

        if let ep = outcome.endpoints {
            let ud = UserDefaults.standard
            ud.set(ep.lrclibSearch, forKey: "config_lrclib_search")
            ud.set(ep.lrclibGet, forKey: "config_lrclib_get")
            ud.set(ep.lyricsOvh, forKey: "config_lyrics_ovh")
            syncSavedEndpoints()
        }

        if outcome.updateAvailable, !outcome.downloadUrl.isEmpty {
            self.updateState = .updateAvailable(
                version: outcome.version,
                releaseNotes: outcome.releaseNotes,
                downloadUrl: outcome.downloadUrl
            )
            self.showUpdateModal = true
            NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)
            return
        }

        self.updateState = .upToDate
        NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)
        if isManualUpdateCheck {
            isManualUpdateCheck = false
            showUpToDateAlert()
        }
    }

    public func startDownloadAndInstall() {
        guard case .updateAvailable(_, _, let dlUrl) = updateState else { return }
        self.updateState = .downloading(progress: 0.0)
        NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)

        dlUrl.withCString { urlPtr in
            targetDmgPath.withCString { destPtr in
                lyrics_core_download_dmg_async(
                    coreHandle,
                    urlPtr,
                    destPtr,
                    0,
                    onRustDownloadProgress,
                    onRustDownloadComplete
                )
            }
        }
    }

    public func cancelUpdateDownload() {
        lyrics_core_cancel_download(coreHandle)
        self.updateState = .idle
        self.showUpdateModal = false
        NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)
    }

    private func installDownloadedUpdate() {
        self.updateState = .installing
        NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)

        let currentAppPath = Bundle.main.bundlePath
        let targetAppPath = currentAppPath.hasPrefix("/Applications")
            ? currentAppPath
            : "/Applications/Lyrics Menu Bar.app"
        let scriptPath = "/tmp/update_lyricsmenubar.sh"
        let mountPoint = "/tmp/LyricsMenuBarMount"

        let scriptContent = """
        #!/bin/bash
        sleep 1.2
        hdiutil detach "\(mountPoint)" -force 2>/dev/null || true
        rm -rf "\(mountPoint)"
        mkdir -p "\(mountPoint)"

        hdiutil attach "\(targetDmgPath)" -nobrowse -mountpoint "\(mountPoint)" -quiet
        sleep 0.6

        APP_SRC=$(find "\(mountPoint)" -maxdepth 1 -name "*.app" | head -n 1)
        if [ -n "$APP_SRC" ] && [ -d "$APP_SRC" ]; then
            rm -rf "\(targetAppPath)"
            cp -R "$APP_SRC" "\(targetAppPath)"
            xattr -cr "\(targetAppPath)" 2>/dev/null || true
        fi

        hdiutil detach "\(mountPoint)" -quiet 2>/dev/null || true
        rm -rf "\(mountPoint)" "\(targetDmgPath)" "\(scriptPath)"
        open -a "\(targetAppPath)"
        """

        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", scriptPath]
            try chmod.run()
            chmod.waitUntilExit()

            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
            launcher.arguments = ["-c", "nohup \(scriptPath) >/dev/null 2>&1 &"]
            try launcher.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        } catch {
            self.updateState = .failed(error: "Installation launcher error: \(error.localizedDescription)")
            NotificationCenter.default.post(name: Self.updateStateDidChangeNotification, object: self)
        }
    }

    private func showUpToDateAlert() {
        SettingsMenuController.isPresentingMenuOrAlert = true
        defer { SettingsMenuController.isPresentingMenuOrAlert = false }
        let alert = NSAlert()
        alert.messageText = "Lyrics Menu Bar is Up to Date"
        alert.informativeText = "You are running the latest version (v\(currentVersion))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
