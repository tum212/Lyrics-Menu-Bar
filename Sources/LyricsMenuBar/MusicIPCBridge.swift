import AppKit
import Foundation

// MARK: - Precompiled AppleScript Runner (Serial Utility Queue)
private final class CompiledAppleScriptRunner: @unchecked Sendable {
    static let shared = CompiledAppleScriptRunner()

    private let queue = DispatchQueue(label: "com.lyricsmenubar.applescript", qos: .utility)
    private var spotifyScript: NSAppleScript?
    private var appleMusicScript: NSAppleScript?

    private static let spotifySource = """
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

    private static let appleMusicSource = """
    if application "Music" is running then
        tell application "Music"
            try
                set pState to player state as string
                if pState is not "stopped" then
                    set t to current track
                    set tName to name of t
                    set tArtist to artist of t
                    set tAlbum to album of t
                    try
                        set tId to persistent ID of t
                    on error
                        set tId to ""
                    end try
                    set tDur to duration of t
                    try
                        set tPos to player position
                    on error
                        set tPos to 0
                    end try
                    return {tName, tArtist, tAlbum, tId, tDur, tPos, pState}
                else
                    return "STOPPED"
                end if
            on error
                return "NOT_PLAYING"
            end try
        end tell
    else
        return "NOT_RUNNING"
    end if
    """

    func poll(
        mode: MusicSourceMode,
        activeSource: MusicSourceMode
    ) async -> (track: TrackModel?, isPlaying: Bool, position: Double, source: MusicSourceMode, isNotRunning: Bool) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                switch mode {
                case .spotify:
                    let s = self.runSpotify()
                    continuation.resume(returning: (s.track, s.isPlaying, s.position, .spotify, s.isNotRunning))
                case .appleMusic:
                    let m = self.runAppleMusic()
                    continuation.resume(returning: (m.track, m.isPlaying, m.position, .appleMusic, m.isNotRunning))
                case .auto:
                    let isSpotifyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").contains { !$0.isTerminated }
                    let isMusicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").contains { !$0.isTerminated }

                    if isMusicRunning && !isSpotifyRunning {
                        let m = self.runAppleMusic()
                        continuation.resume(returning: (m.track, m.isPlaying, m.position, .appleMusic, m.isNotRunning))
                    } else if isSpotifyRunning && !isMusicRunning {
                        let s = self.runSpotify()
                        continuation.resume(returning: (s.track, s.isPlaying, s.position, .spotify, s.isNotRunning))
                    } else if !isSpotifyRunning && !isMusicRunning {
                        continuation.resume(returning: (nil, false, 0, activeSource, true))
                    } else if activeSource == .appleMusic {
                        let m = self.runAppleMusic()
                        if m.isPlaying {
                            continuation.resume(returning: (m.track, true, m.position, .appleMusic, false))
                            return
                        }
                        let s = self.runSpotify()
                        if s.isPlaying {
                            continuation.resume(returning: (s.track, true, s.position, .spotify, false))
                            return
                        }
                        continuation.resume(returning: (m.track, false, m.position, .appleMusic, m.isNotRunning))
                    } else {
                        let s = self.runSpotify()
                        if s.isPlaying {
                            continuation.resume(returning: (s.track, true, s.position, .spotify, false))
                            return
                        }
                        let m = self.runAppleMusic()
                        if m.isPlaying {
                            continuation.resume(returning: (m.track, true, m.position, .appleMusic, false))
                            return
                        }
                        continuation.resume(returning: (s.track, false, s.position, .spotify, s.isNotRunning))
                    }
                }
            }
        }
    }

    private func runSpotify() -> (track: TrackModel?, isPlaying: Bool, position: Double, isNotRunning: Bool) {
        if spotifyScript == nil, let s = NSAppleScript(source: Self.spotifySource) {
            var err: NSDictionary?
            s.compileAndReturnError(&err)
            spotifyScript = s
        }
        guard let script = spotifyScript else { return (nil, false, 0, false) }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
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

            let track = TrackModel(
                id: id,
                name: name,
                artist: artist,
                album: album,
                artworkURL: artworkURL.isEmpty ? nil : artworkURL,
                artworkData: nil,
                duration: duration,
                source: .spotify
            )
            return (track, state == "playing", position, false)
        }
        return (nil, false, 0, false)
    }

    private func runAppleMusic() -> (track: TrackModel?, isPlaying: Bool, position: Double, isNotRunning: Bool) {
        if appleMusicScript == nil, let s = NSAppleScript(source: Self.appleMusicSource) {
            var err: NSDictionary?
            s.compileAndReturnError(&err)
            appleMusicScript = s
        }
        guard let script = appleMusicScript else { return (nil, false, 0, false) }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if output.stringValue == "NOT_RUNNING" {
            return (nil, false, 0, true)
        }
        if output.stringValue == "STOPPED" || output.stringValue == "NOT_PLAYING" {
            return (nil, false, 0, false)
        }
        if output.numberOfItems >= 7 {
            let name = output.atIndex(1)?.stringValue ?? ""
            let artist = output.atIndex(2)?.stringValue ?? ""
            let album = output.atIndex(3)?.stringValue ?? ""
            let id = "apple:\(name)-\(artist)"
            let duration = output.atIndex(5)?.doubleValue ?? 0.0
            let position = output.atIndex(6)?.doubleValue ?? 0.0
            let state = output.atIndex(7)?.stringValue ?? ""

            let track = TrackModel(
                id: id,
                name: name,
                artist: artist,
                album: album,
                artworkURL: nil,
                artworkData: nil,
                duration: duration,
                source: .appleMusic
            )
            return (track, state == "playing", position, false)
        }
        return (nil, false, 0, false)
    }
}

// MARK: - Thin Event-Driven IPC Bridge (Spotify & Apple Music)
@MainActor
public final class MusicIPCBridge: NSObject {
    public static let shared = MusicIPCBridge()

    private var timer: Timer?
    private var isPolling = false

    public var sourceMode: MusicSourceMode {
        MusicSourceMode(defaultsValue: UserDefaults.standard.string(forKey: AppSettingKey.musicSourceMode) ?? "Auto")
    }

    private override init() {
        super.init()
        setupDistributedNotifications()
        startPolling()
    }

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
            if stateStr == "stopped" {
                LyricsCoreEngine.shared.handleStopped(source: .spotify, threshold: 1, isNotRunning: false)
            }
            return
        }

        let engine = LyricsCoreEngine.shared
        let existingArtwork = (engine.currentTrack?.name == name && engine.currentTrack?.artist == artist)
            ? engine.currentTrack?.artworkURL
            : nil
        let track = TrackModel(
            id: trackId.isEmpty ? "\(name)-\(artist)" : trackId,
            name: name,
            artist: artist,
            album: album,
            artworkURL: existingArtwork,
            artworkData: nil,
            duration: duration,
            source: .spotify
        )

        engine.updatePlaybackState(track: track, position: position, isPlaying: newIsPlaying, source: .spotify)
        syncPollingState(isPlaying: newIsPlaying)

        if existingArtwork == nil {
            Task.detached(priority: .userInitiated) {
                let script = "tell application \"Spotify\" to get artwork url of current track"
                if let appleScript = NSAppleScript(source: script) {
                    var err: NSDictionary?
                    let output = appleScript.executeAndReturnError(&err)
                    if let urlStr = output.stringValue, !urlStr.isEmpty {
                        await MainActor.run {
                            LyricsCoreEngine.shared.setSpotifyArtworkURLIfMissing(urlStr, expectedTrackName: name)
                        }
                    }
                }
            }
        }
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
        let trackId = "apple:\(name)-\(artist)"

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
            if stateStr == "stopped" || stateStr.isEmpty {
                LyricsCoreEngine.shared.handleStopped(source: .appleMusic, threshold: 1, isNotRunning: false)
            }
            return
        }

        let track = TrackModel(
            id: trackId,
            name: name,
            artist: artist,
            album: album,
            artworkURL: nil,
            artworkData: nil,
            duration: duration,
            source: .appleMusic
        )
        LyricsCoreEngine.shared.updatePlaybackState(track: track, position: position, isPlaying: newIsPlaying, source: .appleMusic)
        syncPollingState(isPlaying: newIsPlaying)
    }

    private func syncPollingState(isPlaying: Bool) {
        if isPlaying {
            if timer == nil { startPolling() }
        } else {
            stopPolling()
        }
    }

    public func startPolling() {
        timer?.invalidate()
        timer = nil
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollActivePlayer()
            }
        }
        t.tolerance = 0.4
        timer = t
        RunLoop.main.add(t, forMode: .common)
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
        let active = LyricsCoreEngine.shared.activeSource
        Task { [weak self] in
            let res = await CompiledAppleScriptRunner.shared.poll(mode: mode, activeSource: active)
            self?.applyPollResult(res)
        }
    }

    private func applyPollResult(_ res: (track: TrackModel?, isPlaying: Bool, position: Double, source: MusicSourceMode, isNotRunning: Bool)) {
        isPolling = false
        let engine = LyricsCoreEngine.shared
        if res.isNotRunning || res.track == nil {
            engine.handleStopped(source: res.source, threshold: 2, isNotRunning: res.isNotRunning)
            return
        }
        if let track = res.track {
            engine.updatePlaybackState(track: track, position: res.position, isPlaying: res.isPlaying, source: res.source)
            syncPollingState(isPlaying: res.isPlaying)
        }
    }

    nonisolated public static func fetchAppleMusicArtworkData(expectedID: String) -> (persistentID: String, data: Data?) {
        let escapedID = expectedID.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
            if it is running then
                try
                    set aTrack to current track
                    set curId to persistent ID of aTrack
                    if "\(escapedID)" is "" or curId is equal to "\(escapedID)" then
                        try
                            return {curId, raw data of artwork 1 of aTrack}
                        on error
                            return {curId, data of artwork 1 of aTrack}
                        end try
                    else
                        return {curId, ""}
                    end if
                on error
                    return {"", ""}
                end try
            else
                return {"", ""}
            end if
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let desc = appleScript.executeAndReturnError(&error)
            if desc.numberOfItems >= 2 {
                let curId = desc.atIndex(1)?.stringValue ?? ""
                if let data = desc.atIndex(2)?.data, data.count > 64 {
                    return (curId, data)
                }
                return (curId, nil)
            } else if desc.data.count > 64 {
                return (expectedID, desc.data)
            }
        }
        return ("", nil)
    }

    // MARK: - Playback Controls

    public func playPause() {
        let engine = LyricsCoreEngine.shared
        let appName = (engine.activeSource == .appleMusic) ? "Music" : "Spotify"
        runCommand("playpause", on: appName)
        engine.togglePlayStateLocal()
    }

    public func nextTrack() {
        let appName = (LyricsCoreEngine.shared.activeSource == .appleMusic) ? "Music" : "Spotify"
        runCommand("next track", on: appName)
    }

    public func previousTrack() {
        let curTime = LyricsCoreEngine.shared.currentTime()
        if curTime > 3.0 {
            seek(to: 0)
        } else {
            let appName = (LyricsCoreEngine.shared.activeSource == .appleMusic) ? "Music" : "Spotify"
            runCommand("previous track", on: appName)
        }
    }

    public func activateMusicApp() {
        let src = LyricsCoreEngine.shared.activeSource
        let appName = (src == .appleMusic) ? "Music" : "Spotify"
        let bundleId = (src == .appleMusic) ? "com.apple.Music" : "com.spotify.client"
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            runCommand("activate", on: appName)
        }
    }

    public func seek(to time: Double) {
        let target = max(0, time)
        LyricsCoreEngine.shared.seekLocal(to: target)
        let appName = (LyricsCoreEngine.shared.activeSource == .appleMusic) ? "Music" : "Spotify"
        runCommand("set player position to \(target)", on: appName)
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
