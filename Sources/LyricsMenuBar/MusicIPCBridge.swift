import AppKit
import CLyricsCore
import CoreGraphics
import Foundation

// MARK: - Cached YouTube / YouTube Music oEmbed Metadata Resolver (Uses Rust native-tls Pool)

private struct YouTubeOEmbedInfo: Sendable {
    let title: String
    let artist: String
    let artworkURL: String?
}

private final class YouTubeOEmbedResolver: @unchecked Sendable {
    static let shared = YouTubeOEmbedResolver()

    private let lock = NSLock()
    private var cache: [String: YouTubeOEmbedInfo] = [:]
    private var failedUntil: [String: Date] = [:]

    func resolveSync(videoID: String) -> YouTubeOEmbedInfo? {
        lock.lock()
        if let hit = cache[videoID] {
            lock.unlock()
            return hit
        }
        if let until = failedUntil[videoID], Date() < until {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let endpoint = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=\(videoID)&format=json"
        let buf = endpoint.withCString { lyrics_core_download_bytes($0, 4) }
        guard let ptr = buf.data, buf.len > 2 else {
            if buf.data != nil { lyrics_core_free_bytes(buf) }
            lock.lock()
            failedUntil[videoID] = Date().addingTimeInterval(30.0)
            lock.unlock()
            return nil
        }
        let data = Data(bytes: ptr, count: buf.len)
        lyrics_core_free_bytes(buf)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTitle = json["title"] as? String, !rawTitle.isEmpty else {
            return nil
        }
        let rawAuthor = (json["author_name"] as? String) ?? ""
        let thumb = json["thumbnail_url"] as? String

        // If title itself is "Artist - Track" (e.g. label upload), split it; otherwise use author_name (Art Track / Topic)
        var resolvedTitle = WebMusicDomainParser.cleanTrackDecorators(rawTitle)
        var resolvedArtist = WebMusicDomainParser.cleanArtistDecorators(rawAuthor)
        if let dash = rawTitle.range(of: " - ") {
            let left = WebMusicDomainParser.cleanArtistDecorators(String(rawTitle[..<dash.lowerBound]))
            let right = WebMusicDomainParser.cleanTrackDecorators(String(rawTitle[dash.upperBound...]))
            if !left.isEmpty && !right.isEmpty {
                resolvedArtist = left
                resolvedTitle = right
            }
        }

        let info = YouTubeOEmbedInfo(
            title: resolvedTitle,
            artist: resolvedArtist,
            artworkURL: (thumb?.isEmpty == false) ? thumb : nil
        )
        lock.lock()
        if cache.count >= 120 { cache.removeAll(keepingCapacity: true) }
        cache[videoID] = info
        failedUntil.removeValue(forKey: videoID)
        lock.unlock()
        return info
    }
}

// MARK: - Playback Snapshot Produced by Any Detection Layer

private struct PlayerSnapshot: Sendable {
    let track: TrackModel
    let position: Double
    let isPlaying: Bool
    let priority: Int
    let layerRank: Int // 3 = Native/LocalAPI, 2 = MediaRemote, 1 = Browser/Window+Audio
    let isApproximateClock: Bool // true when only window/tab title + CoreAudio active output is available
}

// MARK: - Single Dedicated Serial AppleScript Executor (Zero Concurrent NSAppleScript!)

private final class OSAScriptExecutor: @unchecked Sendable {
    static let shared = OSAScriptExecutor()

    private let queue = DispatchQueue(label: "com.lyricsmenubar.ipc.osa", qos: .utility)
    private var compiledScripts: [String: NSAppleScript] = [:]
    /// Cooldown backoff on -1743 (never permanently locks out an app once the user clicks Allow!)
    private var deniedUntil: [String: Date] = [:]
    private var browserJSBlockedBundleIDs: Set<String> = []

    func clearDenial(for bundleID: String) {
        queue.async {
            self.deniedUntil.removeValue(forKey: bundleID)
            self.browserJSBlockedBundleIDs.remove(bundleID)
        }
    }

    func executeSync(key: String? = nil, source: String, bundleID: String? = nil) -> NSAppleEventDescriptor? {
        queue.sync {
            executeLocked(key: key, source: source, bundleID: bundleID)
        }
    }

    func executeAsync(key: String? = nil, source: String, bundleID: String? = nil) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { continuation in
            queue.async {
                let res = self.executeLocked(key: key, source: source, bundleID: bundleID)
                continuation.resume(returning: res)
            }
        }
    }

    func runBlockAsync<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func executeLocked(key: String?, source: String, bundleID: String?) -> NSAppleEventDescriptor? {
        if let bid = bundleID, let until = deniedUntil[bid], Date() < until {
            return nil
        }

        let script: NSAppleScript
        if let key, let cached = compiledScripts[key] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { return nil }
            var compileErr: NSDictionary?
            created.compileAndReturnError(&compileErr)
            if compileErr != nil {
                return nil
            }
            if let key {
                compiledScripts[key] = created
            }
            script = created
        }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            let errNum = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if errNum == -1743, let bid = bundleID {
                // Short 12s backoff so we don't spam OS prompts, while recovering automatically right after Allow
                deniedUntil[bid] = Date().addingTimeInterval(12.0)
            }
            return nil
        }
        if let bid = bundleID {
            deniedUntil.removeValue(forKey: bid)
        }
        return output
    }

    func isJSBlocked(for bundleID: String) -> Bool {
        browserJSBlockedBundleIDs.contains(bundleID)
    }

    func markJSBlocked(for bundleID: String) {
        browserJSBlockedBundleIDs.insert(bundleID)
    }

    // MARK: - Native Player Pollers (Called on `queue`)

    func pollSpotifyLocked() -> (snapshot: PlayerSnapshot?, isNotRunning: Bool) {
        let src = """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                set pState to player state as string
                if pState is "stopped" then return "STOPPED"
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
                set playerPosition to player position
                return {trackName, trackArtist, trackAlbum, trackId, trackDuration, trackArtworkURL, pState, playerPosition}
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        guard let output = executeLocked(key: "poll_spotify", source: src, bundleID: "com.spotify.client") else {
            return (nil, false)
        }
        if output.stringValue == "NOT_RUNNING" { return (nil, true) }
        if output.stringValue == "STOPPED" { return (nil, false) }
        guard output.numberOfItems >= 8 else { return (nil, false) }

        let name = output.atIndex(1)?.stringValue ?? ""
        let artist = output.atIndex(2)?.stringValue ?? ""
        let album = output.atIndex(3)?.stringValue ?? ""
        let id = output.atIndex(4)?.stringValue ?? ""
        let durRaw = output.atIndex(5)?.doubleValue ?? Double(output.atIndex(5)?.int32Value ?? 0)
        let duration = durRaw / 1000.0
        let artworkURL = output.atIndex(6)?.stringValue ?? ""
        let state = (output.atIndex(7)?.stringValue ?? "").lowercased()
        let position = output.atIndex(8)?.doubleValue ?? 0.0
        guard !name.isEmpty else { return (nil, false) }

        let track = TrackModel(
            id: id.isEmpty ? "spotify:\(name)-\(artist)" : id,
            name: name,
            artist: artist,
            album: album,
            artworkURL: artworkURL.isEmpty ? nil : artworkURL,
            duration: duration,
            sourceID: "com.spotify.client",
            sourceDisplayName: "Spotify",
            audioBundleID: "com.spotify.client"
        )
        return (PlayerSnapshot(track: track, position: position, isPlaying: state == "playing", priority: 100, layerRank: 3, isApproximateClock: false), false)
    }

    func pollAppleMusicLocked() -> (snapshot: PlayerSnapshot?, isNotRunning: Bool) {
        let src = """
        if application id "com.apple.Music" is running then
            tell application id "com.apple.Music"
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
        guard let output = executeLocked(key: "poll_apple_music", source: src, bundleID: "com.apple.Music") else {
            return (nil, false)
        }
        if output.stringValue == "NOT_RUNNING" { return (nil, true) }
        if output.stringValue == "STOPPED" || output.stringValue == "NOT_PLAYING" { return (nil, false) }
        guard output.numberOfItems >= 7 else { return (nil, false) }

        let name = output.atIndex(1)?.stringValue ?? ""
        let artist = output.atIndex(2)?.stringValue ?? ""
        let album = output.atIndex(3)?.stringValue ?? ""
        let persistentId = output.atIndex(4)?.stringValue ?? ""
        let duration = output.atIndex(5)?.doubleValue ?? 0.0
        let position = output.atIndex(6)?.doubleValue ?? 0.0
        let state = (output.atIndex(7)?.stringValue ?? "").lowercased()
        guard !name.isEmpty else { return (nil, false) }

        let track = TrackModel(
            id: persistentId.isEmpty ? "apple:\(name)-\(artist)" : persistentId,
            name: name,
            artist: artist,
            album: album,
            duration: duration,
            sourceID: "com.apple.Music",
            sourceDisplayName: "Apple Music",
            audioBundleID: "com.apple.Music"
        )
        return (PlayerSnapshot(track: track, position: position, isPlaying: state == "playing", priority: 98, layerRank: 3, isApproximateClock: false), false)
    }

    func pollSwinsianLocked() -> (snapshot: PlayerSnapshot?, isNotRunning: Bool) {
        let src = """
        if application id "com.swinsian.Swinsian" is running then
            tell application id "com.swinsian.Swinsian"
                try
                    set pState to player state as string
                    if pState is "stopped" then return "STOPPED"
                    set t to current track
                    set tName to name of t
                    set tArtist to artist of t
                    set tAlbum to album of t
                    set tDur to duration of t
                    set tPos to player position
                    return {tName, tArtist, tAlbum, tDur, tPos, pState}
                on error
                    return "STOPPED"
                end try
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        guard let output = executeLocked(key: "poll_swinsian", source: src, bundleID: "com.swinsian.Swinsian") else {
            return (nil, false)
        }
        if output.stringValue == "NOT_RUNNING" { return (nil, true) }
        if output.stringValue == "STOPPED" { return (nil, false) }
        guard output.numberOfItems >= 6 else { return (nil, false) }
        let name = output.atIndex(1)?.stringValue ?? ""
        let artist = output.atIndex(2)?.stringValue ?? ""
        let album = output.atIndex(3)?.stringValue ?? ""
        let duration = output.atIndex(4)?.doubleValue ?? 0.0
        let position = output.atIndex(5)?.doubleValue ?? 0.0
        let state = (output.atIndex(6)?.stringValue ?? "").lowercased()
        guard !name.isEmpty else { return (nil, false) }

        let track = TrackModel(
            id: "swinsian:\(name)-\(artist)",
            name: name,
            artist: artist,
            album: album,
            duration: duration,
            sourceID: "com.swinsian.Swinsian",
            sourceDisplayName: "Swinsian",
            audioBundleID: "com.swinsian.Swinsian"
        )
        return (PlayerSnapshot(track: track, position: position, isPlaying: state == "playing", priority: 94, layerRank: 3, isApproximateClock: false), false)
    }

    func pollVOXLocked() -> (snapshot: PlayerSnapshot?, isNotRunning: Bool) {
        let src = """
        if application id "com.coppertino.Vox" is running then
            tell application id "com.coppertino.Vox"
                try
                    set pState to player state
                    set tName to track
                    set tArtist to artist
                    set tAlbum to album
                    set tDur to total time
                    set tPos to current time
                    return {tName, tArtist, tAlbum, tDur, tPos, pState}
                on error
                    return "STOPPED"
                end try
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        guard let output = executeLocked(key: "poll_vox", source: src, bundleID: "com.coppertino.Vox") else {
            return (nil, false)
        }
        if output.stringValue == "NOT_RUNNING" { return (nil, true) }
        if output.stringValue == "STOPPED" { return (nil, false) }
        guard output.numberOfItems >= 6 else { return (nil, false) }
        let name = output.atIndex(1)?.stringValue ?? ""
        let artist = output.atIndex(2)?.stringValue ?? ""
        let album = output.atIndex(3)?.stringValue ?? ""
        let duration = output.atIndex(4)?.doubleValue ?? 0.0
        let position = output.atIndex(5)?.doubleValue ?? 0.0
        let isPlaying = (output.atIndex(6)?.int32Value ?? 0) == 1
        guard !name.isEmpty else { return (nil, false) }

        let track = TrackModel(
            id: "vox:\(name)-\(artist)",
            name: name,
            artist: artist,
            album: album,
            duration: duration,
            sourceID: "com.coppertino.Vox",
            sourceDisplayName: "VOX",
            audioBundleID: "com.coppertino.Vox"
        )
        return (PlayerSnapshot(track: track, position: position, isPlaying: isPlaying, priority: 92, layerRank: 3, isApproximateClock: false), false)
    }

    func pollVLCLocked() -> (snapshot: PlayerSnapshot?, isNotRunning: Bool) {
        let src = """
        if application id "org.videolan.vlc" is running then
            tell application id "org.videolan.vlc"
                try
                    set isP to playing
                    set tName to name of current item
                    set tDur to duration of current item
                    set tPos to current time
                    return {tName, tDur, tPos, isP}
                on error
                    return "STOPPED"
                end try
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        guard let output = executeLocked(key: "poll_vlc", source: src, bundleID: "org.videolan.vlc") else {
            return (nil, false)
        }
        if output.stringValue == "NOT_RUNNING" { return (nil, true) }
        if output.stringValue == "STOPPED" { return (nil, false) }
        guard output.numberOfItems >= 4 else { return (nil, false) }
        let rawName = output.atIndex(1)?.stringValue ?? ""
        let duration = output.atIndex(2)?.doubleValue ?? 0.0
        let position = output.atIndex(3)?.doubleValue ?? 0.0
        let isPlaying = output.atIndex(4)?.booleanValue ?? false
        guard !rawName.isEmpty else { return (nil, false) }

        let cleanedFile = (rawName as NSString).deletingPathExtension
        let parsed = WebMusicDomainParser.parseTitle(cleanedFile, appDisplayName: "VLC")
        let trackName = parsed?.trackName ?? cleanedFile
        let artistName = parsed?.artistName ?? ""

        let track = TrackModel(
            id: "vlc:\(trackName)-\(artistName)",
            name: trackName,
            artist: artistName,
            album: "",
            duration: duration,
            sourceID: "org.videolan.vlc",
            sourceDisplayName: "VLC",
            audioBundleID: "org.videolan.vlc"
        )
        return (PlayerSnapshot(track: track, position: position, isPlaying: isPlaying, priority: 76, layerRank: 3, isApproximateClock: false), false)
    }

    // MARK: - Layer 3: Sanctioned Browser Tab & MediaSession Poller (Called on `queue`)

    func pollBrowserLocked(descriptor: PlayerDescriptor, runningBundleID: String, isAudioActive: Bool) -> PlayerSnapshot? {
        let isSafari = (descriptor.driver == .safariBrowser)
        let listScript: String
        if isSafari {
            listScript = """
            if application id "\(runningBundleID)" is running then
                tell application id "\(runningBundleID)"
                    set outList to {}
                    repeat with w in windows
                        try
                            set activeTab to current tab of w
                            set activeURL to URL of activeTab
                            set activeTitle to name of activeTab
                            set end of outList to {"ACTIVE", activeURL, activeTitle}
                        end try
                        try
                            repeat with t in tabs of w
                                set u to URL of t
                                set n to name of t
                                if u is not missing value then
                                    set end of outList to {"TAB", u, n}
                                end if
                            end repeat
                        end try
                    end repeat
                    return outList
                end tell
            end if
            """
        } else {
            listScript = """
            if application id "\(runningBundleID)" is running then
                tell application id "\(runningBundleID)"
                    set outList to {}
                    repeat with w in windows
                        try
                            set activeTab to active tab of w
                            set activeURL to URL of activeTab
                            set activeTitle to title of activeTab
                            set end of outList to {"ACTIVE", activeURL, activeTitle}
                        end try
                        try
                            repeat with t in tabs of w
                                set u to URL of t
                                set n to title of t
                                if u is not missing value then
                                    set end of outList to {"TAB", u, n}
                                end if
                            end repeat
                        end try
                    end repeat
                    return outList
                end tell
            end if
            """
        }

        guard let output = executeLocked(key: "tabs_\(runningBundleID)", source: listScript, bundleID: runningBundleID),
              output.numberOfItems > 0 else {
            return nil
        }

        var bestCandidate: (url: String, title: String, service: String, match: WebMusicMatch, isActiveTab: Bool)?
        for idx in 1...output.numberOfItems {
            guard let item = output.atIndex(idx), item.numberOfItems >= 3 else { continue }
            let kind = item.atIndex(1)?.stringValue ?? ""
            let url = item.atIndex(2)?.stringValue ?? ""
            let title = item.atIndex(3)?.stringValue ?? ""
            guard let service = WebMusicDomainParser.serviceName(forURL: url) else { continue }
            guard let match = WebMusicDomainParser.parseTitle(title, urlString: url, appDisplayName: service) else { continue }
            let isActive = (kind == "ACTIVE")
            if bestCandidate == nil || (isActive && !(bestCandidate?.isActiveTab ?? false)) {
                bestCandidate = (url, title, service, match, isActive)
            }
            if isActive { break }
        }

        guard let found = bestCandidate else { return nil }

        // 1. Enrich YouTube / YouTube Music via official public oEmbed (resolves exact Artist + Artwork even on single-title Art Tracks!)
        var finalTrack = found.match.trackName
        var finalArtist = found.match.artistName
        var finalAlbum = found.match.albumName
        var artworkURL: String?
        var duration: Double = 0
        var position: Double = 0
        var isPlaying = isAudioActive
        var approxClock = true

        if let videoID = WebMusicDomainParser.extractYouTubeVideoID(from: found.url),
           let oembed = YouTubeOEmbedResolver.shared.resolveSync(videoID: videoID) {
            if !oembed.title.isEmpty { finalTrack = oembed.title }
            if !oembed.artist.isEmpty { finalArtist = oembed.artist }
            if let art = oembed.artworkURL { artworkURL = art }
        }

        // 2. Optionally enrich with exact MediaSession / <video>/<audio> timing when user enabled "Allow JavaScript from Apple Events"
        if !isJSBlocked(for: runningBundleID) {
            if let jsData = queryBrowserMediaSessionLocked(
                runningBundleID: runningBundleID,
                isSafari: isSafari,
                targetURL: found.url
            ) {
                if !jsData.title.isEmpty { finalTrack = jsData.title }
                if !jsData.artist.isEmpty { finalArtist = jsData.artist }
                if !jsData.album.isEmpty { finalAlbum = jsData.album }
                if !jsData.artworkURL.isEmpty { artworkURL = jsData.artworkURL }
                if jsData.duration > 0 { duration = jsData.duration }
                if jsData.position >= 0 && jsData.hasMediaElement {
                    position = jsData.position
                    isPlaying = !jsData.paused
                    approxClock = false
                }
            }
        }

        let track = TrackModel(
            id: "web:\(descriptor.id):\(finalTrack.lowercased())-\(finalArtist.lowercased())",
            name: finalTrack,
            artist: finalArtist,
            album: finalAlbum,
            artworkURL: artworkURL,
            duration: duration,
            sourceID: descriptor.id,
            sourceDisplayName: "\(found.service) (\(descriptor.displayName))",
            audioBundleID: runningBundleID
        )
        return PlayerSnapshot(
            track: track,
            position: position,
            isPlaying: isPlaying,
            priority: descriptor.priority + (isAudioActive ? 15 : 0),
            layerRank: approxClock ? 1 : 2,
            isApproximateClock: approxClock
        )
    }

    private struct BrowserJSState {
        let title: String
        let artist: String
        let album: String
        let artworkURL: String
        let position: Double
        let duration: Double
        let paused: Bool
        let hasMediaElement: Bool
    }

    private func queryBrowserMediaSessionLocked(
        runningBundleID: String,
        isSafari: Bool,
        targetURL: String
    ) -> BrowserJSState? {
        let escapedURL = targetURL.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let js = "(function(){try{var ms=navigator.mediaSession&&navigator.mediaSession.metadata;var m=Array.from(document.querySelectorAll('video,audio')).find(function(e){return !e.paused&&e.duration>0;})||document.querySelector('video,audio');var art='';if(ms&&ms.artwork&&ms.artwork.length){art=ms.artwork[ms.artwork.length-1].src||'';}return JSON.stringify({t:ms&&ms.title?ms.title:'',a:ms&&ms.artist?ms.artist:'',al:ms&&ms.album?ms.album:'',art:art,p:m&&isFinite(m.currentTime)?m.currentTime:-1,d:m&&isFinite(m.duration)?m.duration:0,pa:m?!!m.paused:true,hm:!!m});}catch(e){return '';}})()"
        let escapedJS = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let scriptSrc: String
        if isSafari {
            scriptSrc = """
            tell application id "\(runningBundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is "\(escapedURL)" then
                            return do JavaScript "\(escapedJS)" in t
                        end if
                    end repeat
                end repeat
            end tell
            """
        } else {
            scriptSrc = """
            tell application id "\(runningBundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is "\(escapedURL)" then
                            return execute t javascript "\(escapedJS)"
                        end if
                    end repeat
                end repeat
            end tell
            """
        }

        guard let script = NSAppleScript(source: scriptSrc) else { return nil }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if err != nil {
            // Browser has "Allow JavaScript from Apple Events" disabled — remember so we don't retry every 2s
            markJSBlocked(for: runningBundleID)
            return nil
        }
        guard let json = out.stringValue, !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return BrowserJSState(
            title: dict["t"] as? String ?? "",
            artist: dict["a"] as? String ?? "",
            album: dict["al"] as? String ?? "",
            artworkURL: dict["art"] as? String ?? "",
            position: (dict["p"] as? NSNumber)?.doubleValue ?? -1,
            duration: (dict["d"] as? NSNumber)?.doubleValue ?? 0,
            paused: (dict["pa"] as? Bool) ?? true,
            hasMediaElement: (dict["hm"] as? Bool) ?? false
        )
    }
}

// MARK: - Layer 1B: Official Local HTTP API Pollers (Pear/th-ch YTM, YTMDesktop, Cider)

private enum LocalHTTPPlayerClient {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.28
        cfg.timeoutIntervalForResource = 0.35
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    static func pollPearYTM(port: UInt16, descriptor: PlayerDescriptor, runningBundleID: String) async -> PlayerSnapshot? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/song-info") else { return nil }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = (json["title"] as? String) ?? ""
        let artist = (json["artist"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let album = (json["album"] as? String) ?? ""
        let isPaused = (json["isPaused"] as? Bool) ?? true
        let elapsed = (json["elapsedSeconds"] as? NSNumber)?.doubleValue ?? 0
        let duration = (json["songDuration"] as? NSNumber)?.doubleValue ?? 0
        let artURL = (json["imageSrc"] as? String)
        let videoId = (json["videoId"] as? String) ?? "\(title)-\(artist)"

        let track = TrackModel(
            id: "ytm:\(videoId)",
            name: WebMusicDomainParser.cleanTrackDecorators(title),
            artist: WebMusicDomainParser.cleanArtistDecorators(artist),
            album: album,
            artworkURL: (artURL?.isEmpty == false) ? artURL : nil,
            duration: duration,
            sourceID: descriptor.id,
            sourceDisplayName: descriptor.displayName,
            audioBundleID: runningBundleID
        )
        return PlayerSnapshot(track: track, position: elapsed, isPlaying: !isPaused, priority: descriptor.priority, layerRank: 3, isApproximateClock: false)
    }

    static func pollYTMDesktop(port: UInt16, descriptor: PlayerDescriptor, runningBundleID: String) async -> PlayerSnapshot? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/state") else { return nil }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let video = json["video"] as? [String: Any] else {
            return nil
        }
        let title = (video["title"] as? String) ?? ""
        let artist = (video["author"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let album = (video["album"] as? String) ?? ""
        let duration = (video["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
        let player = json["player"] as? [String: Any]
        let trackState = (player?["trackState"] as? NSNumber)?.intValue ?? 0 // 1 = playing
        let position = (player?["videoProgress"] as? NSNumber)?.doubleValue ?? 0
        let thumbs = video["thumbnails"] as? [[String: Any]]
        let artURL = thumbs?.last?["url"] as? String
        let vid = (video["id"] as? String) ?? "\(title)-\(artist)"

        let track = TrackModel(
            id: "ytmd:\(vid)",
            name: WebMusicDomainParser.cleanTrackDecorators(title),
            artist: WebMusicDomainParser.cleanArtistDecorators(artist),
            album: album,
            artworkURL: artURL,
            duration: duration,
            sourceID: descriptor.id,
            sourceDisplayName: descriptor.displayName,
            audioBundleID: runningBundleID
        )
        return PlayerSnapshot(track: track, position: position, isPlaying: trackState == 1, priority: descriptor.priority, layerRank: 3, isApproximateClock: false)
    }

    static func pollCider(port: UInt16, descriptor: PlayerDescriptor, runningBundleID: String) async -> PlayerSnapshot? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/playback/now-playing") else { return nil }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["info"] as? [String: Any] else {
            return nil
        }
        let title = (info["name"] as? String) ?? ""
        let artist = (info["artistName"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let album = (info["albumName"] as? String) ?? ""
        let durMs = (info["durationInMillis"] as? NSNumber)?.doubleValue ?? 0
        let pos = (info["currentPlaybackTime"] as? NSNumber)?.doubleValue ?? 0
        let isPlaying = (info["isPlaying"] as? Bool) ?? false
        var artURL: String?
        if let artDict = info["artwork"] as? [String: Any], var raw = artDict["url"] as? String {
            raw = raw.replacingOccurrences(of: "{w}", with: "600").replacingOccurrences(of: "{h}", with: "600")
            artURL = raw
        }

        let track = TrackModel(
            id: "cider:\(title)-\(artist)",
            name: title,
            artist: artist,
            album: album,
            artworkURL: artURL,
            duration: durMs / 1000.0,
            sourceID: descriptor.id,
            sourceDisplayName: descriptor.displayName,
            audioBundleID: runningBundleID
        )
        return PlayerSnapshot(track: track, position: pos, isPlaying: isPlaying, priority: descriptor.priority, layerRank: 3, isApproximateClock: false)
    }

    static func sendLocalControl(port: UInt16, path: String, body: [String: Any]? = nil) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let body, let data = try? JSONSerialization.data(withJSONObject: body) {
            req.httpBody = data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        session.dataTask(with: req).resume()
    }
}

// MARK: - Layer 2: Direct In-Process MediaRemote Adapter (Sanctioned macOS 13–15.3 Native Support)

private final class OnceGate: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var fired = false
    func tryFire() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if fired { return false }
        fired = true
        return true
    }
}

private final class DirectMediaRemoteAdapter: @unchecked Sendable {
    static let shared = DirectMediaRemoteAdapter()

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias GetClientFn = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    private typealias ClientBundleIDFn = @convention(c) (AnyObject) -> CFString?
    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private let queue = DispatchQueue(label: "com.lyricsmenubar.ipc.mediaremote", qos: .utility)
    private let getInfoFn: GetInfoFn?
    private let getIsPlayingFn: GetIsPlayingFn?
    private let getClientFn: GetClientFn?
    private let clientBundleIDFn: ClientBundleIDFn?
    private let sendCommandFn: SendCommandFn?

    /// Automatically stands down cleanly if macOS 15.4+/26 gates MediaRemote for third-party processes
    private var consecutiveEmptyCount: Int = 0
    private var lastProbeAttempt: Date = .distantPast
    private var isAvailable: Bool { getInfoFn != nil }

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        if let handle {
            getInfoFn = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo").map { unsafeBitCast($0, to: GetInfoFn.self) }
            getIsPlayingFn = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying").map { unsafeBitCast($0, to: GetIsPlayingFn.self) }
            getClientFn = dlsym(handle, "MRMediaRemoteGetNowPlayingClient").map { unsafeBitCast($0, to: GetClientFn.self) }
            clientBundleIDFn = dlsym(handle, "MRMediaRemoteClientGetBundleIdentifier").map { unsafeBitCast($0, to: ClientBundleIDFn.self) }
            sendCommandFn = dlsym(handle, "MRMediaRemoteSendCommand").map { unsafeBitCast($0, to: SendCommandFn.self) }
        } else {
            getInfoFn = nil
            getIsPlayingFn = nil
            getClientFn = nil
            clientBundleIDFn = nil
            sendCommandFn = nil
        }
    }

    private struct MRInfoSnapshot: Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let playbackRate: Double
        let elapsed: Double
        let artworkData: Data?
    }

    func queryNowPlaying() async -> PlayerSnapshot? {
        guard isAvailable, let getInfo = getInfoFn else { return nil }
        // If macOS 15.4+/26 gated MediaRemote, re-check only once every 60s to keep idle overhead near zero
        if consecutiveEmptyCount >= 4 && Date().timeIntervalSince(lastProbeAttempt) < 60.0 {
            return nil
        }
        lastProbeAttempt = Date()

        let infoSnap: MRInfoSnapshot? = await withCheckedContinuation { continuation in
            let gate = OnceGate()
            getInfo(queue) { cfDict in
                guard gate.tryFire() else { return }
                guard let info = cfDict as? [String: Any],
                      let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
                      !title.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let artist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
                let album = (info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String) ?? ""
                let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
                let playbackRate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                var elapsed = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
                if playbackRate > 0, let ts = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                    let delta = Date().timeIntervalSince(ts)
                    if delta > 0 && delta < 300 {
                        elapsed += delta * playbackRate
                    }
                }
                let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                continuation.resume(returning: MRInfoSnapshot(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    playbackRate: playbackRate,
                    elapsed: elapsed,
                    artworkData: artworkData
                ))
            }
            queue.asyncAfter(deadline: .now() + 0.35) {
                guard gate.tryFire() else { return }
                continuation.resume(returning: nil)
            }
        }

        guard let info = infoSnap else {
            consecutiveEmptyCount = min(10, consecutiveEmptyCount + 1)
            return nil
        }
        consecutiveEmptyCount = 0

        let title = info.title
        let artist = info.artist
        let album = info.album
        let duration = info.duration
        let playbackRate = info.playbackRate
        let elapsed = info.elapsed
        let artworkData = info.artworkData

        let isPlayingFlag: Bool
        if playbackRate > 0 {
            isPlayingFlag = true
        } else if let getIsPlaying = getIsPlayingFn {
            isPlayingFlag = await withCheckedContinuation { cont in
                let gate = OnceGate()
                getIsPlaying(queue) { playing in
                    guard gate.tryFire() else { return }
                    cont.resume(returning: playing)
                }
                queue.asyncAfter(deadline: .now() + 0.2) {
                    guard gate.tryFire() else { return }
                    cont.resume(returning: false)
                }
            }
        } else {
            isPlayingFlag = false
        }

        var clientBID = ""
        if let getClient = getClientFn, let getBID = clientBundleIDFn {
            clientBID = await withCheckedContinuation { cont in
                let gate = OnceGate()
                getClient(queue) { clientObj in
                    guard gate.tryFire() else { return }
                    if let obj = clientObj, let cfStr = getBID(obj) {
                        cont.resume(returning: cfStr as String)
                    } else {
                        cont.resume(returning: "")
                    }
                }
                queue.asyncAfter(deadline: .now() + 0.2) {
                    guard gate.tryFire() else { return }
                    cont.resume(returning: "")
                }
            }
        }

        let registry = MusicSourceRegistry.shared
        let canonical = registry.canonicalDescriptor(forBundleID: clientBID)
        let sourceID = canonical?.id ?? (clientBID.isEmpty ? "com.apple.mediaremote" : clientBID)
        let displayName = canonical?.displayName ?? registry.displayName(forBundleID: clientBID)
        let audioBID = clientBID.isEmpty ? sourceID : clientBID

        let track = TrackModel(
            id: "mr:\(sourceID):\(title.lowercased())-\(artist.lowercased())",
            name: WebMusicDomainParser.cleanTrackDecorators(title),
            artist: WebMusicDomainParser.cleanArtistDecorators(artist),
            album: album,
            artworkData: artworkData,
            duration: duration,
            sourceID: sourceID,
            sourceDisplayName: displayName,
            audioBundleID: audioBID
        )
        return PlayerSnapshot(
            track: track,
            position: max(0, elapsed),
            isPlaying: isPlayingFlag,
            priority: canonical?.priority ?? 78,
            layerRank: 2,
            isApproximateClock: false
        )
    }

    @discardableResult
    func sendCommand(_ command: UInt32) -> Bool {
        guard let fn = sendCommandFn, consecutiveEmptyCount < 4 else { return false }
        return fn(command, nil)
    }
}

// MARK: - Layer 3B: Sanctioned Window-Title + CoreAudio Active-Output Inspector (TIDAL, Deezer, Qobuz, Amazon, IINA, etc.)

private enum WindowTitlePlayerInspector {
    static func inspect(descriptor: PlayerDescriptor, app: NSRunningApplication, isAudioActive: Bool) -> PlayerSnapshot? {
        guard descriptor.supportsWindowTitleFallback else { return nil }
        let targetPID = app.processIdentifier
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for win in rawList {
            guard let ownerPID = win[kCGWindowOwnerPID as String] as? pid_t, ownerPID == targetPID else { continue }
            guard let title = win[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            let layer = (win[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }

            if let match = WebMusicDomainParser.parseTitle(title, appDisplayName: descriptor.displayName) {
                let track = TrackModel(
                    id: "win:\(descriptor.id):\(match.trackName.lowercased())-\(match.artistName.lowercased())",
                    name: match.trackName,
                    artist: match.artistName,
                    album: match.albumName,
                    duration: 0,
                    sourceID: descriptor.id,
                    sourceDisplayName: descriptor.displayName,
                    audioBundleID: app.bundleIdentifier ?? descriptor.id
                )
                return PlayerSnapshot(
                    track: track,
                    position: 0,
                    isPlaying: isAudioActive,
                    priority: descriptor.priority + (isAudioActive ? 10 : 0),
                    layerRank: 1,
                    isApproximateClock: true
                )
            }
        }
        return nil
    }
}

// MARK: - Universal Multi-App Music IPC Bridge

@MainActor
public final class MusicIPCBridge: NSObject {
    public static let shared = MusicIPCBridge()

    private var timer: Timer?
    private var isPolling = false
    private var needsImmediateRepoll = false
    private var eventSequence: UInt64 = 0
    private var lastObservedTrackIDForApproxClock: String = ""
    private var approxTrackStartUptime: TimeInterval = 0

    public var sourceSelection: MusicSourceSelection {
        MusicSourceSelection(defaultsValue: UserDefaults.standard.string(forKey: AppSettingKey.musicSourceMode) ?? "Auto")
    }

    public var universalNowPlayingEnabled: Bool {
        if UserDefaults.standard.object(forKey: AppSettingKey.universalNowPlayingEnabled) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: AppSettingKey.universalNowPlayingEnabled)
    }

    private override init() {
        super.init()
        setupDistributedNotifications()
        setupWorkspaceNotifications()
        startPolling()
    }

    // MARK: - Notifications

    private func setupWorkspaceNotifications() {
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(handleAppTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        wnc.addObserver(self, selector: #selector(handleAppLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    }

    @objc private func handleAppTerminated(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bid = app.bundleIdentifier else { return }
        let canonical = MusicSourceRegistry.shared.canonicalDescriptor(forBundleID: bid)?.id ?? bid
        let engine = LyricsCoreEngine.shared
        if engine.activeSourceID == canonical || engine.activeAudioBundleID == bid {
            eventSequence &+= 1
            engine.handleStopped(sourceID: canonical, threshold: 0, isNotRunning: true)
            pollActivePlayer()
        }
    }

    @objc private func handleAppLaunched(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bid = app.bundleIdentifier,
              MusicSourceRegistry.shared.isKnownBundleID(bid) else { return }
        pollActivePlayer()
    }

    private func setupDistributedNotifications() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(handleSpotifyNotification(_:)), name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        dnc.addObserver(self, selector: #selector(handleAppleMusicNotification(_:)), name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        dnc.addObserver(self, selector: #selector(handleSwinsianNotification(_:)), name: NSNotification.Name("com.swinsian.Swinsian-Track-Playing"), object: nil)
        dnc.addObserver(self, selector: #selector(handleSwinsianNotification(_:)), name: NSNotification.Name("com.swinsian.Swinsian-Track-Paused"), object: nil)
        dnc.addObserver(self, selector: #selector(handleSwinsianNotification(_:)), name: NSNotification.Name("com.swinsian.Swinsian-Track-Stopped"), object: nil)
        dnc.addObserver(self, selector: #selector(handleVOXNotification(_:)), name: NSNotification.Name("com.coppertino.Vox.trackChanged"), object: nil)
    }

    private func shouldAcceptNotification(fromSourceID sourceID: String, isPlaying: Bool) -> Bool {
        switch sourceSelection {
        case .specific(let bid):
            return bid == sourceID
        case .auto:
            let eng = LyricsCoreEngine.shared
            // A paused background app must NEVER hijack a different currently playing player!
            if !isPlaying && eng.isPlaying && eng.activeSourceID != sourceID {
                return false
            }
            return true
        }
    }

    @objc private func handleSpotifyNotification(_ notif: Notification) {
        guard let info = notif.userInfo else { return }
        let stateStr = (info["Player State"] as? String)?.lowercased() ?? ""
        let newIsPlaying = (stateStr == "playing")
        guard shouldAcceptNotification(fromSourceID: "com.spotify.client", isPlaying: newIsPlaying) else { return }

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

        eventSequence &+= 1
        guard !name.isEmpty else {
            if stateStr == "stopped" {
                LyricsCoreEngine.shared.handleStopped(sourceID: "com.spotify.client", threshold: 1, isNotRunning: false)
            }
            return
        }

        let engine = LyricsCoreEngine.shared
        let existingArtwork = (engine.currentTrack?.name == name && engine.currentTrack?.artist == artist)
            ? engine.currentTrack?.artworkURL
            : nil
        let track = TrackModel(
            id: trackId.isEmpty ? "spotify:\(name)-\(artist)" : trackId,
            name: name,
            artist: artist,
            album: album,
            artworkURL: existingArtwork,
            duration: duration,
            sourceID: "com.spotify.client",
            sourceDisplayName: "Spotify",
            audioBundleID: "com.spotify.client"
        )

        engine.updatePlaybackState(track: track, position: position, isPlaying: newIsPlaying)
        ensurePollingInterval(isPlaying: newIsPlaying)

        if existingArtwork == nil {
            Task {
                let script = "tell application id \"com.spotify.client\" to get artwork url of current track"
                if let out = await OSAScriptExecutor.shared.executeAsync(key: "spotify_art_url", source: script, bundleID: "com.spotify.client"),
                   let urlStr = out.stringValue, !urlStr.isEmpty {
                    LyricsCoreEngine.shared.setArtworkURLIfMissing(urlStr, expectedTrackName: name)
                }
            }
        }
    }

    @objc private func handleAppleMusicNotification(_ notif: Notification) {
        guard let info = notif.userInfo else { return }
        let stateStr = (info["Player State"] as? String)?.lowercased() ?? ""
        let newIsPlaying = (stateStr == "playing")
        guard shouldAcceptNotification(fromSourceID: "com.apple.Music", isPlaying: newIsPlaying) else { return }

        let name = (info["Name"] as? String) ?? ""
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""

        // Match AppleScript Persistent ID format when available so artwork lookup matches seamlessly
        var trackId = "apple:\(name)-\(artist)"
        if let pidNum = info["PersistentID"] as? NSNumber {
            trackId = String(format: "%016llX", pidNum.uint64Value)
        } else if let pidStr = info["PersistentID"] as? String, !pidStr.isEmpty {
            trackId = pidStr
        }

        var duration: Double = 0
        if let durNum = info["Total Time"] as? NSNumber {
            duration = durNum.doubleValue / 1000.0
        } else if let durDouble = info["Total Time"] as? Double {
            duration = durDouble / 1000.0
        }

        let engine = LyricsCoreEngine.shared
        let sameTrack = (engine.currentTrack?.sourceID == "com.apple.Music"
            && engine.currentTrack?.name == name
            && engine.currentTrack?.artist == artist)

        // Preserve interpolated clock when Apple Music omits "Player Position" on play/pause notifications!
        let position: Double
        if let posNum = info["Player Position"] as? NSNumber {
            position = posNum.doubleValue
        } else if let posDouble = info["Player Position"] as? Double {
            position = posDouble
        } else if sameTrack {
            position = engine.currentTime()
        } else {
            position = 0
        }

        eventSequence &+= 1
        guard !name.isEmpty else {
            if stateStr == "stopped" || stateStr.isEmpty {
                engine.handleStopped(sourceID: "com.apple.Music", threshold: 1, isNotRunning: false)
            }
            return
        }

        let track = TrackModel(
            id: trackId,
            name: name,
            artist: artist,
            album: album,
            duration: duration,
            sourceID: "com.apple.Music",
            sourceDisplayName: "Apple Music",
            audioBundleID: "com.apple.Music"
        )
        engine.updatePlaybackState(track: track, position: position, isPlaying: newIsPlaying)
        ensurePollingInterval(isPlaying: newIsPlaying)
    }

    @objc private func handleSwinsianNotification(_ notif: Notification) {
        if notif.name.rawValue.hasSuffix("Stopped") {
            LyricsCoreEngine.shared.handleStopped(sourceID: "com.swinsian.Swinsian", threshold: 1, isNotRunning: false)
        } else {
            pollActivePlayer()
        }
    }

    @objc private func handleVOXNotification(_ notif: Notification) {
        pollActivePlayer()
    }

    // MARK: - Adaptive Polling Scheduler (2.0s active, 4.0s idle discovery for Universal apps)

    private var currentPollInterval: TimeInterval = 2.0

    private func ensurePollingInterval(isPlaying: Bool) {
        let target: TimeInterval = isPlaying ? 2.0 : 3.5
        if timer == nil || abs(currentPollInterval - target) > 0.1 {
            scheduleTimer(interval: target)
        }
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        currentPollInterval = interval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollActivePlayer()
            }
        }
        t.tolerance = interval * 0.2
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    public func startPolling() {
        scheduleTimer(interval: 2.0)
        pollActivePlayer()
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    public func cleanup() {
        stopPolling()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    public func clearAutomationDenialAndPoll(for bundleID: String) {
        OSAScriptExecutor.shared.clearDenial(for: bundleID)
        pollActivePlayer()
    }

    public func pollActivePlayer() {
        if isPolling {
            needsImmediateRepoll = true
            return
        }
        isPolling = true
        needsImmediateRepoll = false

        let seqAtStart = eventSequence
        let selection = self.sourceSelection
        let universalEnabled = self.universalNowPlayingEnabled
        let currentSourceID = LyricsCoreEngine.shared.activeSourceID

        Task { [weak self] in
            let outcome = await Self.performUniversalPoll(
                selection: selection,
                universalEnabled: universalEnabled,
                stickySourceID: currentSourceID
            )
            self?.finishPoll(outcome: outcome, startedAtSeq: seqAtStart)
        }
    }

    private struct PollOutcome: Sendable {
        let winner: PlayerSnapshot?
        let stoppedSourceID: String
        let isNotRunning: Bool
    }

    private static func performUniversalPoll(
        selection: MusicSourceSelection,
        universalEnabled: Bool,
        stickySourceID: String
    ) async -> PollOutcome {
        let registry = MusicSourceRegistry.shared
        let activeAudioBundles = AudioTapBridge.activeOutputAudioBundleIDs()

        // Specific-source mode
        if case .specific(let targetBID) = selection {
            guard let desc = registry.canonicalDescriptor(forBundleID: targetBID) else {
                // Unknown custom bundle ID — try MediaRemote
                if let mr = await DirectMediaRemoteAdapter.shared.queryNowPlaying(),
                   mr.track.sourceID == targetBID || mr.track.audioBundleID == targetBID {
                    return PollOutcome(winner: mr, stoppedSourceID: targetBID, isNotRunning: false)
                }
                return PollOutcome(winner: nil, stoppedSourceID: targetBID, isNotRunning: true)
            }
            let running = registry.runningApp(for: desc)
            guard let app = running else {
                return PollOutcome(winner: nil, stoppedSourceID: desc.id, isNotRunning: true)
            }
            let isAudioActive = activeAudioBundles.contains(desc.id)
                || (app.bundleIdentifier.map { activeAudioBundles.contains($0) } ?? false)
            if let snap = await pollSinglePlayer(desc: desc, app: app, isAudioActive: isAudioActive) {
                return PollOutcome(winner: snap, stoppedSourceID: desc.id, isNotRunning: false)
            }
            if let mr = await DirectMediaRemoteAdapter.shared.queryNowPlaying(), mr.track.sourceID == desc.id {
                return PollOutcome(winner: mr, stoppedSourceID: desc.id, isNotRunning: false)
            }
            return PollOutcome(winner: nil, stoppedSourceID: desc.id, isNotRunning: false)
        }

        // AUTO mode: Poll all running players across Layers 1, 2, and 3 cleanly
        let runningList = registry.runningPlayers()
        var candidates: [PlayerSnapshot] = []

        // Layer 1: Native & Local-API players
        for (desc, app) in runningList {
            if !universalEnabled && desc.id != "com.spotify.client" && desc.id != "com.apple.Music" {
                continue
            }
            let isAudioActive = activeAudioBundles.contains(desc.id)
                || (app.bundleIdentifier.map { activeAudioBundles.contains($0) } ?? false)

            switch desc.driver {
            case .spotify, .appleMusic, .swinsian, .vox, .vlc, .pearYTM, .ytmDesktop, .cider:
                if let snap = await pollSinglePlayer(desc: desc, app: app, isAudioActive: isAudioActive) {
                    candidates.append(snap)
                }
            case .windowAndAudio, .chromiumBrowser, .safariBrowser:
                // Handled below only if universalEnabled
                break
            }
        }

        // If a high-confidence Layer 1 player is actively playing, we already have the exact winner!
        if let playingNative = candidates.filter({ $0.isPlaying }).max(by: { $0.priority < $1.priority }) {
            return PollOutcome(winner: playingNative, stoppedSourceID: playingNative.track.sourceID, isNotRunning: false)
        }

        // Layer 2: Direct In-Process MediaRemote (works on macOS 13–15.3 across all apps/browsers)
        if universalEnabled, let mrSnap = await DirectMediaRemoteAdapter.shared.queryNowPlaying() {
            candidates.append(mrSnap)
            if mrSnap.isPlaying {
                return PollOutcome(winner: mrSnap, stoppedSourceID: mrSnap.track.sourceID, isNotRunning: false)
            }
        }

        // Layer 3: Sanctioned Desktop Window-Title + Browser Tab/MediaSession (works on macOS 15.4–26!)
        if universalEnabled {
            for (desc, app) in runningList {
                let isAudioActive = activeAudioBundles.contains(desc.id)
                    || (app.bundleIdentifier.map { activeAudioBundles.contains($0) } ?? false)

                switch desc.driver {
                case .windowAndAudio:
                    if let snap = WindowTitlePlayerInspector.inspect(descriptor: desc, app: app, isAudioActive: isAudioActive) {
                        candidates.append(snap)
                    }
                case .chromiumBrowser, .safariBrowser:
                    // Prioritize scanning browsers that are actively outputting audio or sticky paused
                    if isAudioActive || desc.id == stickySourceID {
                        if let snap = await pollSinglePlayer(desc: desc, app: app, isAudioActive: isAudioActive) {
                            candidates.append(snap)
                        }
                    }
                case .pearYTM, .ytmDesktop, .cider:
                    // Window-title fallback if the user hasn't enabled the desktop app's local API server
                    if !candidates.contains(where: { $0.track.sourceID == desc.id }) {
                        if let snap = WindowTitlePlayerInspector.inspect(descriptor: desc, app: app, isAudioActive: isAudioActive) {
                            candidates.append(snap)
                        }
                    }
                default:
                    break
                }
            }
        }

        // Strict Arbiter: Playing > Sticky Paused > Highest Priority Paused
        if let playingBest = candidates.filter({ $0.isPlaying }).max(by: { lhs, rhs in
            if lhs.layerRank != rhs.layerRank { return lhs.layerRank < rhs.layerRank }
            return lhs.priority < rhs.priority
        }) {
            return PollOutcome(winner: playingBest, stoppedSourceID: playingBest.track.sourceID, isNotRunning: false)
        }

        if let stickyPaused = candidates.first(where: { $0.track.sourceID == stickySourceID }) {
            return PollOutcome(winner: stickyPaused, stoppedSourceID: stickyPaused.track.sourceID, isNotRunning: false)
        }

        if let pausedBest = candidates.max(by: { $0.priority < $1.priority }) {
            return PollOutcome(winner: pausedBest, stoppedSourceID: pausedBest.track.sourceID, isNotRunning: false)
        }

        let anyKnownRunning = !runningList.isEmpty
        return PollOutcome(winner: nil, stoppedSourceID: stickySourceID, isNotRunning: !anyKnownRunning)
    }

    private static func pollSinglePlayer(
        desc: PlayerDescriptor,
        app: NSRunningApplication,
        isAudioActive: Bool
    ) async -> PlayerSnapshot? {
        let runningBID = app.bundleIdentifier ?? desc.id
        switch desc.driver {
        case .spotify:
            return await OSAScriptExecutor.shared.runBlockAsync { OSAScriptExecutor.shared.pollSpotifyLocked().snapshot }
        case .appleMusic:
            return await OSAScriptExecutor.shared.runBlockAsync { OSAScriptExecutor.shared.pollAppleMusicLocked().snapshot }
        case .swinsian:
            return await OSAScriptExecutor.shared.runBlockAsync { OSAScriptExecutor.shared.pollSwinsianLocked().snapshot }
        case .vox:
            return await OSAScriptExecutor.shared.runBlockAsync { OSAScriptExecutor.shared.pollVOXLocked().snapshot }
        case .vlc:
            return await OSAScriptExecutor.shared.runBlockAsync { OSAScriptExecutor.shared.pollVLCLocked().snapshot }
        case .pearYTM(let port):
            if let snap = await LocalHTTPPlayerClient.pollPearYTM(port: port, descriptor: desc, runningBundleID: runningBID) {
                return snap
            }
            return WindowTitlePlayerInspector.inspect(descriptor: desc, app: app, isAudioActive: isAudioActive)
        case .ytmDesktop(let port):
            if let snap = await LocalHTTPPlayerClient.pollYTMDesktop(port: port, descriptor: desc, runningBundleID: runningBID) {
                return snap
            }
            return WindowTitlePlayerInspector.inspect(descriptor: desc, app: app, isAudioActive: isAudioActive)
        case .cider(let port):
            if let snap = await LocalHTTPPlayerClient.pollCider(port: port, descriptor: desc, runningBundleID: runningBID) {
                return snap
            }
            return WindowTitlePlayerInspector.inspect(descriptor: desc, app: app, isAudioActive: isAudioActive)
        case .chromiumBrowser, .safariBrowser:
            return await OSAScriptExecutor.shared.runBlockAsync {
                OSAScriptExecutor.shared.pollBrowserLocked(descriptor: desc, runningBundleID: runningBID, isAudioActive: isAudioActive)
            }
        case .windowAndAudio:
            return WindowTitlePlayerInspector.inspect(descriptor: desc, app: app, isAudioActive: isAudioActive)
        }
    }

    private func finishPoll(outcome: PollOutcome, startedAtSeq: UInt64) {
        isPolling = false
        defer {
            if needsImmediateRepoll {
                needsImmediateRepoll = false
                pollActivePlayer()
            }
        }

        // Discard stale poll result if a fresher DistributedNotification arrived while polling
        guard eventSequence == startedAtSeq else { return }

        let engine = LyricsCoreEngine.shared
        guard let winner = outcome.winner else {
            engine.handleStopped(sourceID: outcome.stoppedSourceID, threshold: 2, isNotRunning: outcome.isNotRunning)
            ensurePollingInterval(isPlaying: false)
            return
        }

        // If Layer 3 approximate clock (window/tab title without JS MediaSession), keep smooth local elapsed counter
        let resolvedPosition: Double
        if winner.isApproximateClock {
            if winner.track.id != lastObservedTrackIDForApproxClock {
                lastObservedTrackIDForApproxClock = winner.track.id
                approxTrackStartUptime = ProcessInfo.processInfo.systemUptime
                resolvedPosition = 0.0
            } else {
                resolvedPosition = engine.currentTime()
            }
        } else {
            lastObservedTrackIDForApproxClock = ""
            resolvedPosition = winner.position
        }

        engine.updatePlaybackState(track: winner.track, position: resolvedPosition, isPlaying: winner.isPlaying)
        ensurePollingInterval(isPlaying: winner.isPlaying)
    }

    // MARK: - Apple Music Native Artwork (Runs on Serial OSA Executor!)

    nonisolated public static func fetchAppleMusicArtworkData(expectedID: String) -> (persistentID: String, data: Data?) {
        let escapedID = expectedID.hasPrefix("apple:") ? "" : expectedID.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application id "com.apple.Music"
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
        guard let desc = OSAScriptExecutor.shared.executeSync(source: script, bundleID: "com.apple.Music") else {
            return ("", nil)
        }
        if desc.numberOfItems >= 2 {
            let curId = desc.atIndex(1)?.stringValue ?? ""
            if let data = desc.atIndex(2)?.data, data.count > 64 {
                return (curId, data)
            }
            return (curId, nil)
        } else if desc.data.count > 64 {
            return (expectedID, desc.data)
        }
        return ("", nil)
    }

    // MARK: - Unified Playback Controls (All Apps & Browsers)

    public func playPause() {
        let engine = LyricsCoreEngine.shared
        guard engine.currentTrack != nil else { return }
        let srcID = engine.activeSourceID
        let desc = MusicSourceRegistry.shared.canonicalDescriptor(forBundleID: srcID)

        switch desc?.driver {
        case .spotify:
            runOSACommand("playpause", bundleID: "com.spotify.client")
        case .appleMusic:
            runOSACommand("playpause", bundleID: "com.apple.Music")
        case .swinsian:
            runOSACommand("playpause", bundleID: "com.swinsian.Swinsian")
        case .vox:
            runOSACommand("playpause", bundleID: "com.coppertino.Vox")
        case .vlc:
            runOSACommand("play", bundleID: "org.videolan.vlc")
        case .pearYTM(let port):
            LocalHTTPPlayerClient.sendLocalControl(port: port, path: "/api/v1/toggle-play")
        case .cider(let port):
            LocalHTTPPlayerClient.sendLocalControl(port: port, path: "/api/v1/playback/playpause")
        default:
            if !DirectMediaRemoteAdapter.shared.sendCommand(2) { // kMRTogglePlayPause = 2
                postSystemMediaKey(16) // NX_KEYTYPE_PLAY
            }
        }
        engine.togglePlayStateLocal()
    }

    public func nextTrack() {
        let engine = LyricsCoreEngine.shared
        guard engine.currentTrack != nil else { return }
        let srcID = engine.activeSourceID
        let desc = MusicSourceRegistry.shared.canonicalDescriptor(forBundleID: srcID)

        switch desc?.driver {
        case .spotify:
            runOSACommand("next track", bundleID: "com.spotify.client")
        case .appleMusic:
            runOSACommand("next track", bundleID: "com.apple.Music")
        case .swinsian:
            runOSACommand("next track", bundleID: "com.swinsian.Swinsian")
        case .vox:
            runOSACommand("next", bundleID: "com.coppertino.Vox")
        case .vlc:
            runOSACommand("next", bundleID: "org.videolan.vlc")
        case .pearYTM(let port):
            LocalHTTPPlayerClient.sendLocalControl(port: port, path: "/api/v1/next")
        case .cider(let port):
            LocalHTTPPlayerClient.sendLocalControl(port: port, path: "/api/v1/playback/next")
        default:
            if !DirectMediaRemoteAdapter.shared.sendCommand(4) { // kMRNextTrack = 4
                postSystemMediaKey(17) // NX_KEYTYPE_NEXT
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pollActivePlayer()
        }
    }

    public func previousTrack() {
        let engine = LyricsCoreEngine.shared
        guard engine.currentTrack != nil else { return }
        let srcID = engine.activeSourceID
        let desc = MusicSourceRegistry.shared.canonicalDescriptor(forBundleID: srcID)
        let curTime = engine.currentTime()

        let supportsExactSeek: Bool
        switch desc?.driver {
        case .spotify, .appleMusic, .swinsian, .vox, .vlc, .pearYTM, .cider:
            supportsExactSeek = true
        default:
            supportsExactSeek = false
        }

        if supportsExactSeek && curTime > 3.0 {
            seek(to: 0)
            return
        }

        switch desc?.driver {
        case .spotify:
            runOSACommand("previous track", bundleID: "com.spotify.client")
        case .appleMusic:
            runOSACommand("previous track", bundleID: "com.apple.Music")
        case .swinsian:
            runOSACommand("previous track", bundleID: "com.swinsian.Swinsian")
        case .vox:
            runOSACommand("previous", bundleID: "com.coppertino.Vox")
        case .vlc:
            runOSACommand("previous", bundleID: "org.videolan.vlc")
        case .pearYTM(let port):
            LocalHTTPPlayerClient.sendLocalControl(port: port, path: "/api/v1/previous")
        case .cider(let port):
            LocalHTTPPlayerClient.sendLocalControl(port: port, path: "/api/v1/playback/previous")
        default:
            if !DirectMediaRemoteAdapter.shared.sendCommand(5) { // kMRPreviousTrack = 5
                postSystemMediaKey(18) // NX_KEYTYPE_PREVIOUS
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pollActivePlayer()
        }
    }

    public func seek(to time: Double) {
        guard time.isFinite else { return }
        let target = max(0, time)
        let engine = LyricsCoreEngine.shared
        engine.seekLocal(to: target)

        let srcID = engine.activeSourceID
        let desc = MusicSourceRegistry.shared.canonicalDescriptor(forBundleID: srcID)
        switch desc?.driver {
        case .spotify:
            runOSACommand("set player position to \(target)", bundleID: "com.spotify.client")
        case .appleMusic:
            runOSACommand("set player position to \(target)", bundleID: "com.apple.Music")
        case .swinsian:
            runOSACommand("set player position to \(target)", bundleID: "com.swinsian.Swinsian")
        case .vox:
            runOSACommand("set current time to \(target)", bundleID: "com.coppertino.Vox")
        case .vlc:
            runOSACommand("set current time to \(Int(target))", bundleID: "org.videolan.vlc")
        case .pearYTM(let port):
            LocalHTTPPlayerClient.sendLocalControl(port: port, path: "/api/v1/seek-to", body: ["seconds": target])
        case .cider(let port):
            LocalHTTPPlayerClient.sendLocalControl(port: port, path: "/api/v1/playback/seek", body: ["position": target])
        default:
            break
        }
    }

    public func activateMusicApp() {
        let engine = LyricsCoreEngine.shared
        let bundleId = engine.activeAudioBundleID.isEmpty ? engine.activeSourceID : engine.activeAudioBundleID
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first(where: { !$0.isTerminated }) {
            running.activate(options: [])
            return
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func runOSACommand(_ command: String, bundleID: String) {
        let script = "tell application id \"\(bundleID)\" to \(command)"
        Task {
            _ = await OSAScriptExecutor.shared.executeAsync(source: script, bundleID: bundleID)
        }
    }

    private func postSystemMediaKey(_ keyCode: Int) {
        // Synthesize standard macOS AUX media key down/up event (NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8)
        func send(keyDown: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: keyDown ? 0xA00 : 0xB00)
            let data1 = (keyCode << 16) | ((keyDown ? 0xA : 0xB) << 8)
            if let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent {
                ev.post(tap: .cghidEventTap)
            }
        }
        send(keyDown: true)
        send(keyDown: false)
    }
}
