import Foundation
import Combine
import AppKit

public enum MusicSourceMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "Auto"
    case spotify = "Spotify"
    case appleMusic = "Apple Music"
    
    public var id: String { rawValue }
}

public struct MusicTrack: Equatable, @unchecked Sendable {
    public var id: String
    public var name: String
    public var artist: String
    public var album: String
    public var artworkURL: String?
    public var artworkImage: NSImage?
    public var duration: Double // in seconds
    public var source: MusicSourceMode
    
    public init(
        id: String,
        name: String,
        artist: String,
        album: String,
        artworkURL: String? = nil,
        artworkImage: NSImage? = nil,
        duration: Double,
        source: MusicSourceMode = .spotify
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.artworkImage = artworkImage
        self.duration = duration
        self.source = source
    }
}

// Backwards compatibility alias
public typealias SpotifyTrack = MusicTrack

@MainActor
public final class MusicService: NSObject, ObservableObject {
    @Published public var currentTrack: MusicTrack?
    @Published public var isPlaying: Bool = false
    @Published public var playbackPosition: Double = 0.0
    @Published public var lastUpdateDate: Date = Date()
    @Published public var activeSource: MusicSourceMode = .spotify
    
    private var lastMonotonicTime: TimeInterval = 0.0
    private var monotonicTrackId: String = ""
    
    /// Returns monotonic, jitter-free playback time for 60 FPS karaoke rendering
    public var currentTime: TimeInterval {
        let now = Date()
        let raw = isPlaying ? playbackPosition + now.timeIntervalSince(lastUpdateDate) : playbackPosition
        let clampedRaw = max(0, raw)
        
        guard let track = currentTrack else {
            lastMonotonicTime = 0.0
            return 0.0
        }
        
        // If track changed, playback paused, or significant seek occurred (backward > 0.25s, forward > 1.2s)
        if monotonicTrackId != track.id || !isPlaying || clampedRaw < (lastMonotonicTime - 0.25) || clampedRaw > (lastMonotonicTime + 1.2) {
            monotonicTrackId = track.id
            lastMonotonicTime = clampedRaw
            return clampedRaw
        }
        
        // Strict forward monotonic constraint during continuous playback:
        // Eliminates any backward time jumps and word flicker caused by AppleScript latency!
        if clampedRaw > lastMonotonicTime {
            lastMonotonicTime = clampedRaw
        }
        return lastMonotonicTime
    }
    
    private var timer: Timer?
    private var isPolling = false
    
    // Artwork caching for Apple Music
    private var cachedMusicArtworkId: String?
    private var cachedMusicArtworkImage: NSImage?
    
    public var sourceMode: MusicSourceMode {
        get {
            let val = UserDefaults.standard.string(forKey: "musicSourceMode") ?? "Auto"
            return MusicSourceMode(rawValue: val) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "musicSourceMode")
            pollActivePlayer()
        }
    }
    
    public override init() {
        super.init()
        setupDistributedNotifications()
        startPolling()
    }
    
    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    // MARK: - Distributed Notifications (Event-Driven IPC)
    private func setupDistributedNotifications() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self,
            selector: #selector(handleSpotifyNotification(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
        dnc.addObserver(
            self,
            selector: #selector(handleAppleMusicNotification(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
    }
    
    @objc private func handleSpotifyNotification(_ notif: Notification) {
        guard let info = notif.userInfo else { return }
        let mode = self.sourceMode
        guard mode == .spotify || mode == .auto else { return }
        
        let stateStr = (info["Player State"] as? String)?.lowercased() ?? ""
        let newIsPlaying = (stateStr == "playing")
        let name = (info["Name"] as? String) ?? ""
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""
        let trackId = (info["Track ID"] as? String) ?? ""
        
        var duration: Double = 0
        if let durNum = info["Duration"] as? NSNumber {
            duration = durNum.doubleValue / 1000.0
        } else if let durDouble = info["Duration"] as? Double {
            duration = durDouble / 1000.0
        }
        
        var position: Double = 0
        if let posNum = info["Playback Position"] as? NSNumber {
            position = posNum.doubleValue
        } else if let posDouble = info["Playback Position"] as? Double {
            position = posDouble
        }
        
        guard !name.isEmpty else {
            if stateStr == "stopped" && self.activeSource == .spotify {
                self.currentTrack = nil
                self.isPlaying = false
                self.playbackPosition = 0
            }
            return
        }
        
        // Preserve existing artwork if track id hasn't changed
        let existingArtwork = (self.currentTrack?.id == trackId) ? self.currentTrack?.artworkURL : nil
        let track = MusicTrack(
            id: trackId.isEmpty ? "\(name)-\(artist)" : trackId,
            name: name,
            artist: artist,
            album: album,
            artworkURL: existingArtwork,
            artworkImage: nil,
            duration: duration,
            source: .spotify
        )
        
        self.updatePlaybackState(track: track, position: position, isPlaying: newIsPlaying, source: .spotify, bundleID: "com.spotify.client")
    }
    
    @objc private func handleAppleMusicNotification(_ notif: Notification) {
        guard let info = notif.userInfo else { return }
        let mode = self.sourceMode
        guard mode == .appleMusic || mode == .auto else { return }
        
        let stateStr = (info["Player State"] as? String)?.lowercased() ?? ""
        let newIsPlaying = (stateStr == "playing")
        let name = (info["Name"] as? String) ?? ""
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""
        let trackId = (info["PersistentID"] as? String) ?? (info["Persistent ID"] as? String) ?? "\(name)-\(artist)"
        
        var duration: Double = 0
        if let durNum = info["Total Time"] as? NSNumber {
            duration = durNum.doubleValue / 1000.0
        } else if let durDouble = info["Total Time"] as? Double {
            duration = durDouble / 1000.0
        }
        
        var position: Double = 0
        if let posNum = info["Player Position"] as? NSNumber {
            position = posNum.doubleValue
        } else if let posDouble = info["Player Position"] as? Double {
            position = posDouble
        }
        
        guard !name.isEmpty else {
            if (stateStr == "stopped" || stateStr.isEmpty) && self.activeSource == .appleMusic {
                self.currentTrack = nil
                self.isPlaying = false
                self.playbackPosition = 0
            }
            return
        }
        
        var artworkImg: NSImage? = nil
        if trackId == self.cachedMusicArtworkId {
            artworkImg = self.cachedMusicArtworkImage
        }
        
        let track = MusicTrack(
            id: trackId,
            name: name,
            artist: artist,
            album: album,
            artworkURL: nil,
            artworkImage: artworkImg,
            duration: duration,
            source: .appleMusic
        )
        
        self.updatePlaybackState(track: track, position: position, isPlaying: newIsPlaying, source: .appleMusic, bundleID: "com.apple.Music")
        
        // Asynchronously fetch artwork if missing
        if artworkImg == nil {
            Task.detached(priority: .userInitiated) { [weak self] in
                if let data = Self.fetchAppleMusicArtworkData() {
                    let img = NSImage(data: data)
                    await self?.updateCachedArtwork(trackId: trackId, image: img)
                }
            }
        }
    }
    
    private func updateCachedArtwork(trackId: String, image: NSImage?) {
        self.cachedMusicArtworkId = trackId
        self.cachedMusicArtworkImage = image
        if self.currentTrack?.id == trackId {
            self.currentTrack?.artworkImage = image
        }
    }
    
    // MARK: - Polling
    
    public func startPolling() {
        timer?.invalidate()
        timer = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollActivePlayer()
            }
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        pollActivePlayer()
    }
    
    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
    
    public func cleanup() {
        stopPolling()
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    public func pollActivePlayer() {
        guard !isPolling else { return }
        isPolling = true
        
        let mode = self.sourceMode
        let active = self.activeSource
        Task.detached(priority: .userInitiated) { [weak self] in
            let res: (track: MusicTrack?, isPlaying: Bool, position: Double, source: MusicSourceMode, isNotRunning: Bool)
            switch mode {
            case .spotify:
                let s = Self.executeSpotifyScript()
                res = (s.track, s.isPlaying, s.position, .spotify, s.isNotRunning)
            case .appleMusic:
                let m = Self.executeAppleMusicScript()
                res = (m.track, m.isPlaying, m.position, .appleMusic, m.isNotRunning)
            case .auto:
                let a = Self.executeAutoDetectScript(activeSource: active)
                res = (a.track, a.isPlaying, a.position, a.source, a.isNotRunning)
            }
            await self?.applyPollResult(res)
        }
    }
    
    private func applyPollResult(_ res: (track: MusicTrack?, isPlaying: Bool, position: Double, source: MusicSourceMode, isNotRunning: Bool)) {
        self.isPolling = false
        if res.isNotRunning {
            if self.activeSource == res.source {
                self.currentTrack = nil
                self.isPlaying = false
                self.playbackPosition = 0.0
            }
            return
        }
        if let track = res.track {
            var finalTrack = track
            if track.source == .appleMusic {
                if track.id == self.cachedMusicArtworkId, let img = self.cachedMusicArtworkImage {
                    finalTrack.artworkImage = img
                } else if track.artworkImage != nil {
                    self.cachedMusicArtworkId = track.id
                    self.cachedMusicArtworkImage = track.artworkImage
                }
            }
            self.updatePlaybackState(track: finalTrack, position: res.position, isPlaying: res.isPlaying, source: res.source, bundleID: res.source == .appleMusic ? "com.apple.Music" : "com.spotify.client")
        }
    }
    
    // MARK: - Standalone AppleScript Helpers (Zero Self Capture)
    
    nonisolated private static func executeSpotifyScript() -> (track: MusicTrack?, isPlaying: Bool, position: Double, isNotRunning: Bool) {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackId to id of current track
                set trackDuration to duration of current track
                try
                    set trackArtworkURL to artwork url of current track
                on error
                    set trackArtworkURL to ""
                end try
                set playerState to player state as string
                set playerPosition to player position
                return {trackName, trackArtist, trackAlbum, trackId, trackDuration, trackArtworkURL, playerState, playerPosition}
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return (nil, false, 0, false) }
        let output = appleScript.executeAndReturnError(&error)
        if output.stringValue == "NOT_RUNNING" {
            return (nil, false, 0, true)
        }
        if output.numberOfItems >= 8 {
            let name = output.atIndex(1)?.stringValue ?? ""
            let artist = output.atIndex(2)?.stringValue ?? ""
            let album = output.atIndex(3)?.stringValue ?? ""
            let id = output.atIndex(4)?.stringValue ?? ""
            let durRaw = output.atIndex(5)?.doubleValue ?? Double(output.atIndex(5)?.int32Value ?? 0)
            let duration = durRaw / 1000.0
            let artworkURL = output.atIndex(6)?.stringValue ?? ""
            let state = output.atIndex(7)?.stringValue ?? ""
            let position = output.atIndex(8)?.doubleValue ?? 0.0
            
            let track = MusicTrack(
                id: id,
                name: name,
                artist: artist,
                album: album,
                artworkURL: artworkURL.isEmpty ? nil : artworkURL,
                artworkImage: nil,
                duration: duration,
                source: .spotify
            )
            return (track, state == "playing", position, false)
        }
        return (nil, false, 0, false)
    }
    
    nonisolated private static func executeAppleMusicScript() -> (track: MusicTrack?, isPlaying: Bool, position: Double, isNotRunning: Bool) {
        let script = """
        if application "Music" is running then
            tell application "Music"
                try
                    set t to current track
                    set tName to name of t
                    set tArtist to artist of t
                    set tAlbum to album of t
                    set tId to persistent ID of t
                    set tDur to duration of t
                    set tPos to player position
                    set tState to player state as string
                    return {tName, tArtist, tAlbum, tId, tDur, tPos, tState}
                on error
                    return "NOT_PLAYING"
                end try
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return (nil, false, 0, false) }
        let output = appleScript.executeAndReturnError(&error)
        if output.stringValue == "NOT_RUNNING" || output.stringValue == "NOT_PLAYING" {
            return (nil, false, 0, true)
        }
        if output.numberOfItems >= 7 {
            let name = output.atIndex(1)?.stringValue ?? ""
            let artist = output.atIndex(2)?.stringValue ?? ""
            let album = output.atIndex(3)?.stringValue ?? ""
            let id = output.atIndex(4)?.stringValue ?? ""
            let duration = output.atIndex(5)?.doubleValue ?? 0.0
            let position = output.atIndex(6)?.doubleValue ?? 0.0
            let state = output.atIndex(7)?.stringValue ?? ""
            
            let track = MusicTrack(
                id: id,
                name: name,
                artist: artist,
                album: album,
                artworkURL: nil,
                artworkImage: nil,
                duration: duration,
                source: .appleMusic
            )
            return (track, state == "playing", position, false)
        }
        return (nil, false, 0, false)
    }
    
    nonisolated private static func executeAutoDetectScript(activeSource: MusicSourceMode) -> (track: MusicTrack?, isPlaying: Bool, position: Double, source: MusicSourceMode, isNotRunning: Bool) {
        let isSpotifyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").contains { !$0.isTerminated }
        let isMusicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").contains { !$0.isTerminated }
        
        if isMusicRunning && !isSpotifyRunning {
            let m = executeAppleMusicScript()
            return (m.track, m.isPlaying, m.position, .appleMusic, m.isNotRunning)
        }
        if isSpotifyRunning && !isMusicRunning {
            let s = executeSpotifyScript()
            return (s.track, s.isPlaying, s.position, .spotify, s.isNotRunning)
        }
        if !isSpotifyRunning && !isMusicRunning {
            return (nil, false, 0, activeSource, true)
        }
        
        if activeSource == .appleMusic {
            let m = executeAppleMusicScript()
            if m.isPlaying { return (m.track, true, m.position, .appleMusic, false) }
            let s = executeSpotifyScript()
            if s.isPlaying { return (s.track, true, s.position, .spotify, false) }
            if m.track != nil { return (m.track, false, m.position, .appleMusic, false) }
            return (s.track, false, s.position, .spotify, s.isNotRunning)
        } else {
            let s = executeSpotifyScript()
            if s.isPlaying { return (s.track, true, s.position, .spotify, false) }
            let m = executeAppleMusicScript()
            if m.isPlaying { return (m.track, true, m.position, .appleMusic, false) }
            if s.track != nil { return (s.track, false, s.position, .spotify, false) }
            return (m.track, false, m.position, .appleMusic, m.isNotRunning)
        }
    }
    
    nonisolated private static func fetchAppleMusicArtworkData() -> Data? {
        let script = """
        tell application "Music"
            if it is running then
                try
                    set aTrack to current track
                    return data of artwork 1 of aTrack
                on error
                    return ""
                end try
            else
                return ""
            end if
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let desc = appleScript.executeAndReturnError(&error)
            let data = desc.data
            if !data.isEmpty { return data }
        }
        return nil
    }
    
    // MARK: - Unified Anti-Jitter Playback Synchronization
    
    private func updatePlaybackState(track: MusicTrack, position: Double, isPlaying: Bool, source: MusicSourceMode, bundleID: String) {
        let isTrackChanged = (self.currentTrack?.id != track.id)
        let isPlayStateChanged = (self.isPlaying != isPlaying)
        
        let now = Date()
        let expectedPosition = self.isPlaying
            ? self.playbackPosition + now.timeIntervalSince(self.lastUpdateDate)
            : self.playbackPosition
        let delta = position - expectedPosition
        
        if isTrackChanged || isPlayStateChanged || delta < -0.25 || delta > 1.2 {
            // Track change, play/pause toggle, backward seek, or large forward jump: hard resync
            self.playbackPosition = position
            self.lastUpdateDate = now
            self.lastMonotonicTime = position
            self.monotonicTrackId = track.id
        } else if abs(delta) > 0.35 {
            // Gentle slew for small genuine clock drift over many minutes
            self.playbackPosition += delta * 0.1
        }
        
        if self.activeSource != source {
            self.activeSource = source
            NotificationCenter.default.post(name: Notification.Name("ActiveMusicSourceChanged"), object: nil, userInfo: ["bundleID": bundleID])
        }
        if isPlayStateChanged {
            self.isPlaying = isPlaying
        }
        if isTrackChanged {
            self.currentTrack = track
        }
    }
    
    // MARK: - Playback Controls
    
    public func playPause() {
        let appName = (activeSource == .appleMusic) ? "Music" : "Spotify"
        runCommand("playpause", on: appName)
        isPlaying.toggle()
    }
    
    public func nextTrack() {
        let appName = (activeSource == .appleMusic) ? "Music" : "Spotify"
        runCommand("next track", on: appName)
    }
    
    public func previousTrack() {
        let appName = (activeSource == .appleMusic) ? "Music" : "Spotify"
        runCommand("previous track", on: appName)
    }
    
    public func seek(to time: TimeInterval) {
        let targetTime = max(0, time)
        self.playbackPosition = targetTime
        self.lastUpdateDate = Date()
        self.lastMonotonicTime = targetTime
        let appName = (activeSource == .appleMusic) ? "Music" : "Spotify"
        runCommand("set player position to \(targetTime)", on: appName)
    }
    
    private func runCommand(_ command: String, on appName: String) {
        let script = "tell application \"\(appName)\" to \(command)"
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
    }
}
