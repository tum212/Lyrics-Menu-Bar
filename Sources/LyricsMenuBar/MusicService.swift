import Foundation
import Combine
import AppKit

public enum MusicSourceMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "Auto"
    case spotify = "Spotify"
    case appleMusic = "Apple Music"
    
    public var id: String { rawValue }
}

public struct MusicTrack: Equatable {
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

public final class MusicService: ObservableObject, @unchecked Sendable {
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
        
        if monotonicTrackId != track.id || !isPlaying || abs(clampedRaw - lastMonotonicTime) > 1.2 {
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
    
    public init() {
        startPolling()
    }
    
    deinit {
        stopPolling()
    }
    
    public func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollActivePlayer()
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
    
    public func pollActivePlayer() {
        guard !isPolling else { return }
        isPolling = true
        
        let mode = self.sourceMode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.isPolling = false }
            guard let self = self else { return }
            
            switch mode {
            case .spotify:
                self.pollSpotify()
            case .appleMusic:
                self.pollAppleMusic()
            case .auto:
                self.pollAutoDetect()
            }
        }
    }
    
    // MARK: - Auto-Detection
    
    private func pollAutoDetect() {
        let isSpotifyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").contains { !$0.isTerminated }
        let isMusicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").contains { !$0.isTerminated }
        
        if isMusicRunning && !isSpotifyRunning {
            self.pollAppleMusic()
            return
        }
        if isSpotifyRunning && !isMusicRunning {
            self.pollSpotify()
            return
        }
        if !isSpotifyRunning && !isMusicRunning {
            DispatchQueue.main.async {
                if self.currentTrack != nil {
                    self.currentTrack = nil
                    self.isPlaying = false
                    self.playbackPosition = 0.0
                }
            }
            return
        }
        
        // Fast path: if the currently active source is playing, stay on it without checking the other
        if self.activeSource == .appleMusic {
            let musicStatus = self.getMusicQuickStatus()
            if musicStatus.isPlaying {
                self.pollAppleMusic()
                return
            }
            let spotifyStatus = self.getSpotifyQuickStatus()
            if spotifyStatus.isPlaying {
                self.pollSpotify()
                return
            }
            if musicStatus.hasTrack {
                self.pollAppleMusic()
            } else if spotifyStatus.hasTrack {
                self.pollSpotify()
            }
        } else {
            let spotifyStatus = self.getSpotifyQuickStatus()
            if spotifyStatus.isPlaying {
                self.pollSpotify()
                return
            }
            let musicStatus = self.getMusicQuickStatus()
            if musicStatus.isPlaying {
                self.pollAppleMusic()
                return
            }
            if spotifyStatus.hasTrack {
                self.pollSpotify()
            } else if musicStatus.hasTrack {
                self.pollAppleMusic()
            }
        }
    }
    
    private func getSpotifyQuickStatus() -> (hasTrack: Bool, isPlaying: Bool) {
        let script = """
        tell application "Spotify"
            if it is running then
                return (player state as string)
            end if
            return "not running"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let output = appleScript.executeAndReturnError(&error)
            if let state = output.stringValue {
                return (state != "not running", state == "playing")
            }
        }
        return (false, false)
    }
    
    private func getMusicQuickStatus() -> (hasTrack: Bool, isPlaying: Bool) {
        let script = """
        tell application "Music"
            if it is running then
                return (player state as string)
            end if
            return "not running"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let output = appleScript.executeAndReturnError(&error)
            if let state = output.stringValue {
                return (state != "not running", state == "playing")
            }
        }
        return (false, false)
    }
    
    // MARK: - Spotify Polling
    
    private func pollSpotify() {
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
                
                return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackId & "|||" & trackDuration & "|||" & trackArtworkURL & "|||" & playerState & "|||" & playerPosition
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let output = appleScript.executeAndReturnError(&error)
            if let stringValue = output.stringValue {
                if stringValue == "NOT_RUNNING" {
                    DispatchQueue.main.async {
                        if self.activeSource == .spotify {
                            self.currentTrack = nil
                            self.isPlaying = false
                            self.playbackPosition = 0.0
                        }
                    }
                } else {
                    let components = stringValue.components(separatedBy: "|||")
                    if components.count >= 8 {
                        let name = components[0]
                        let artist = components[1]
                        let album = components[2]
                        let id = components[3]
                        let duration = (Double(components[4]) ?? 0) / 1000.0
                        let artworkURL = components[5]
                        let state = components[6]
                        let position = Double(components[7]) ?? 0.0
                        
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
                        
                        DispatchQueue.main.async {
                            let newIsPlaying = (state == "playing")
                            self.updatePlaybackState(track: track, position: position, isPlaying: newIsPlaying, source: .spotify, bundleID: "com.spotify.client")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Apple Music Polling
    
    private func pollAppleMusic() {
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
                    return tName & "|||" & tArtist & "|||" & tAlbum & "|||" & tId & "|||" & tDur & "|||" & tPos & "|||" & tState
                on error
                    return "NOT_PLAYING"
                end try
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let output = appleScript.executeAndReturnError(&error)
            if let stringValue = output.stringValue {
                if stringValue == "NOT_RUNNING" || stringValue == "NOT_PLAYING" {
                    DispatchQueue.main.async {
                        if self.activeSource == .appleMusic {
                            self.currentTrack = nil
                            self.isPlaying = false
                            self.playbackPosition = 0.0
                        }
                    }
                } else {
                    let components = stringValue.components(separatedBy: "|||")
                    if components.count >= 7 {
                        let name = components[0]
                        let artist = components[1]
                        let album = components[2]
                        let id = components[3]
                        let duration = Double(components[4]) ?? 0.0
                        let position = Double(components[5]) ?? 0.0
                        let state = components[6]
                        
                        // Fetch Artwork for Apple Music if track changed
                        var artworkImg: NSImage? = nil
                        if id == self.cachedMusicArtworkId {
                            artworkImg = self.cachedMusicArtworkImage
                        } else {
                            artworkImg = self.fetchAppleMusicArtwork()
                            self.cachedMusicArtworkId = id
                            self.cachedMusicArtworkImage = artworkImg
                        }
                        
                        let track = MusicTrack(
                            id: id,
                            name: name,
                            artist: artist,
                            album: album,
                            artworkURL: nil,
                            artworkImage: artworkImg,
                            duration: duration,
                            source: .appleMusic
                        )
                        
                        DispatchQueue.main.async {
                            let newIsPlaying = (state == "playing")
                            self.updatePlaybackState(track: track, position: position, isPlaying: newIsPlaying, source: .appleMusic, bundleID: "com.apple.Music")
                        }
                    }
                }
            }
        }
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
        
        if isTrackChanged || isPlayStateChanged || abs(delta) > 1.2 {
            // Track change, play/pause toggle, or user scrub/seek: hard resync
            self.playbackPosition = position
            self.lastUpdateDate = now
            self.lastMonotonicTime = position
            self.monotonicTrackId = track.id
        } else if abs(delta) > 0.35 {
            // Gentle slew for small genuine clock drift over many minutes:
            // Adjust base playbackPosition slightly without resetting lastUpdateDate
            self.playbackPosition += delta * 0.1
        }
        // If abs(delta) <= 0.35, leave playbackPosition & lastUpdateDate untouched!
        // The monotonic system clock provides perfectly smooth, zero-jitter 60 FPS interpolation.
        
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
    
    private func fetchAppleMusicArtwork() -> NSImage? {
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
            if !data.isEmpty, let img = NSImage(data: data) {
                return img
            }
        }
        return nil
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
        DispatchQueue.main.async {
            self.playbackPosition = targetTime
            self.lastUpdateDate = Date()
            self.lastMonotonicTime = targetTime
        }
        let appName = (activeSource == .appleMusic) ? "Music" : "Spotify"
        runCommand("set player position to \(targetTime)", on: appName)
    }
    
    private func runCommand(_ command: String, on appName: String) {
        let script = "tell application \"\(appName)\" to \(command)"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
    }
}
