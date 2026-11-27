import AppKit
import Foundation

// MARK: - Universal Music Streaming Player Catalog

public enum PlayerCategory: String, Sendable, CaseIterable {
    case native
    case desktopStreaming
    case mediaPlayer
    case browser

    public var sectionTitle: String {
        switch self {
        case .native: return "Native Music Apps"
        case .desktopStreaming: return "Streaming Apps"
        case .mediaPlayer: return "Media Players"
        case .browser: return "Web Browsers"
        }
    }
}

public enum NativeIPCDriver: Equatable, Sendable {
    case spotify
    case appleMusic
    case swinsian
    case vox
    case vlc
    case pearYTM(port: UInt16)
    case ytmDesktop(port: UInt16)
    case cider(port: UInt16)
    case chromiumBrowser
    case safariBrowser
    case windowAndAudio
}

public struct PlayerDescriptor: Sendable, Identifiable, Equatable {
    public let id: String // Canonical bundle ID
    public let displayName: String
    public let category: PlayerCategory
    public let alternateBundleIDs: [String]
    public let driver: NativeIPCDriver
    public let priority: Int
    public let audioHelperPrefixes: [String]
    public let supportsWindowTitleFallback: Bool

    public var allBundleIDs: [String] {
        [id] + alternateBundleIDs
    }

    public func matches(bundleID: String) -> Bool {
        if id.caseInsensitiveCompare(bundleID) == .orderedSame { return true }
        if alternateBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return true
        }
        return false
    }
}

public enum MusicSourceSelection: Equatable, Sendable {
    case auto
    case specific(bundleID: String)

    public var defaultsValue: String {
        switch self {
        case .auto: return "Auto"
        case .specific(let bid): return bid
        }
    }

    public init(defaultsValue: String) {
        let trimmed = defaultsValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "", "Auto":
            self = .auto
        case "Spotify":
            self = .specific(bundleID: "com.spotify.client")
        case "Apple Music":
            self = .specific(bundleID: "com.apple.Music")
        default:
            if let canonical = MusicSourceRegistry.shared.canonicalDescriptor(forBundleID: trimmed) {
                self = .specific(bundleID: canonical.id)
            } else {
                self = .specific(bundleID: trimmed)
            }
        }
    }
}

// MARK: - Web Music Streaming Domain Parser

public struct WebMusicMatch: Sendable {
    public let serviceName: String
    public let trackName: String
    public let artistName: String
    public let albumName: String
}

public enum WebMusicDomainParser {
    public static let supportedHostFragments: [(fragment: String, serviceName: String)] = [
        ("music.youtube.com", "YouTube Music"),
        ("open.spotify.com", "Spotify Web"),
        ("music.apple.com", "Apple Music Web"),
        ("soundcloud.com", "SoundCloud"),
        ("listen.tidal.com", "TIDAL Web"),
        ("deezer.com", "Deezer"),
        ("play.qobuz.com", "Qobuz"),
        ("music.amazon.", "Amazon Music"),
        ("bandcamp.com", "Bandcamp"),
        ("youtube.com/watch", "YouTube"),
    ]

    public static func serviceName(forURL urlString: String) -> String? {
        let lower = urlString.lowercased()
        for entry in supportedHostFragments {
            if lower.contains(entry.fragment) {
                return entry.serviceName
            }
        }
        return nil
    }

    /// Parse a browser tab title or desktop window title into (track, artist).
    public static func parseTitle(_ rawTitle: String, urlString: String = "", appDisplayName: String = "") -> WebMusicMatch? {
        let cleaned = stripNoisePrefixes(rawTitle)
        guard !cleaned.isEmpty else { return nil }

        let service = serviceName(forURL: urlString) ?? (appDisplayName.isEmpty ? "Web Player" : appDisplayName)
        let lowerURL = urlString.lowercased()

        // Ignore generic home / browse / search pages
        let genericTitles: Set<String> = [
            "youtube music", "spotify", "spotify – web player", "spotify - web player",
            "apple music", "soundcloud", "tidal", "deezer", "qobuz", "amazon music",
            "bandcamp", "youtube", "cider", "home", "search", "library", "explore",
            "your library", "listen now", "browse", "new tab", "untitled", "vlc media player"
        ]
        if genericTitles.contains(cleaned.lowercased()) {
            return nil
        }

        // Remove known trailing service suffixes
        var body = cleaned
        let suffixes = [
            " - YouTube Music", " – YouTube Music", " — YouTube Music",
            " - YouTube", " – YouTube", " — YouTube",
            " | Spotify", " - Spotify", " – Spotify",
            " - Apple Music", " – Apple Music", " on Apple Music",
            " | Listen online for free on SoundCloud",
            " | Listen online on SoundCloud",
            " | Free Listening on SoundCloud",
            " on SoundCloud", " - SoundCloud", " | SoundCloud",
            " - TIDAL", " | TIDAL", " – TIDAL",
            " - Deezer", " | Deezer", " – Deezer",
            " - Qobuz", " | Qobuz",
            " - Amazon Music", " | Amazon Music",
            " | Bandcamp", " - Bandcamp",
            " - Cider", " - VLC media player", " - IINA"
        ]
        for suffix in suffixes {
            if body.lowercased().hasSuffix(suffix.lowercased()) {
                body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if body.isEmpty || genericTitles.contains(body.lowercased()) {
            return nil
        }

        // SoundCloud pattern: "Track by Artist" or "Stream Track by Artist"
        if lowerURL.contains("soundcloud.com") || service.lowercased().contains("soundcloud") {
            var scBody = body
            if scBody.lowercased().hasPrefix("stream ") {
                scBody = String(scBody.dropFirst(7))
            }
            if let byRange = scBody.range(of: " by ", options: [.caseInsensitive, .backwards]) {
                let title = cleanTrackDecorators(String(scBody[..<byRange.lowerBound]))
                let artist = cleanArtistDecorators(String(scBody[byRange.upperBound...]))
                if !title.isEmpty && !artist.isEmpty {
                    return WebMusicMatch(serviceName: service, trackName: title, artistName: artist, albumName: "")
                }
            }
        }

        let isStandardYouTubeWatch = lowerURL.contains("youtube.com/watch") && !lowerURL.contains("music.youtube.com")

        // Spotify Web / Apple Music / TIDAL bullet separator: "Track • Artist" or "Track · Artist"
        for bullet in [" • ", " · ", " — ", " – "] {
            if let range = body.range(of: bullet) {
                let left = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty && !right.isEmpty {
                    // For YouTube watch URLs, "Artist - Track" is standard; for Spotify/Apple/TIDAL/YTM, "Track • Artist" or "Track - Artist"
                    if isStandardYouTubeWatch {
                        return WebMusicMatch(
                            serviceName: service,
                            trackName: cleanTrackDecorators(right),
                            artistName: cleanArtistDecorators(left),
                            albumName: ""
                        )
                    }
                    return WebMusicMatch(
                        serviceName: service,
                        trackName: cleanTrackDecorators(left),
                        artistName: cleanArtistDecorators(right),
                        albumName: ""
                    )
                }
            }
        }

        // Standard "A - B" separator
        if let dashRange = body.range(of: " - ") {
            let left = String(body[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(body[dashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !left.isEmpty && !right.isEmpty {
                // On YouTube watch pages & Bandcamp, standard title format is "Artist - Track Name"
                if isStandardYouTubeWatch || lowerURL.contains("bandcamp.com") {
                    let track = cleanTrackDecorators(right)
                    let artist = cleanArtistDecorators(left)
                    if !track.isEmpty && !artist.isEmpty {
                        return WebMusicMatch(serviceName: service, trackName: track, artistName: artist, albumName: "")
                    }
                } else {
                    // Spotify Web, TIDAL Desktop, Deezer, Qobuz, Amazon Music, YouTube Music: "Track - Artist"
                    let track = cleanTrackDecorators(left)
                    let artist = cleanArtistDecorators(right)
                    if !track.isEmpty && !artist.isEmpty {
                        return WebMusicMatch(serviceName: service, trackName: track, artistName: artist, albumName: "")
                    }
                }
            }
        }

        // Bandcamp / Apple Music "Track | Artist"
        if let pipeRange = body.range(of: " | ") {
            let left = cleanTrackDecorators(String(body[..<pipeRange.lowerBound]))
            let right = cleanArtistDecorators(String(body[pipeRange.upperBound...]))
            if !left.isEmpty && !right.isEmpty {
                return WebMusicMatch(serviceName: service, trackName: left, artistName: right, albumName: "")
            }
        }

        return nil
    }

    private static func stripNoisePrefixes(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading audio indicator glyphs or notification counters e.g. "(1) ", "▶ ", "🔊 "
        let leadingSymbols = ["▶ ", "► ", "⏸ ", "🔊 ", "🔈 ", "♫ ", "♪ ", "🎵 "]
        for sym in leadingSymbols {
            if s.hasPrefix(sym) {
                s = String(s.dropFirst(sym.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if s.hasPrefix("("), let closeIdx = s.firstIndex(of: ")") {
            let inside = s[s.index(after: s.startIndex)..<closeIdx]
            if !inside.isEmpty && inside.allSatisfy({ $0.isNumber }) {
                s = String(s[s.index(after: closeIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    public static func cleanTrackDecorators(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "\\s*\\(Official\\s*(Music\\s*)?Video\\)",
            "\\s*\\[Official\\s*(Music\\s*)?Video\\]",
            "\\s*\\(Official\\s*Audio\\)",
            "\\s*\\[Official\\s*Audio\\]",
            "\\s*\\(Official\\s*Lyric\\s*Video\\)",
            "\\s*\\[Official\\s*Lyric\\s*Video\\]",
            "\\s*\\(Lyric\\s*Video\\)",
            "\\s*\\[Lyrics\\]",
            "\\s*\\(Lyrics\\)",
            "\\s*\\(HD\\)",
            "\\s*\\(4K\\)",
            "\\s*\\|\\s*Official.*$"
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func cleanArtistDecorators(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Topic", " – Topic", " VEVO", " Official"] {
            if s.lowercased().hasSuffix(suffix.lowercased()) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Music Source Registry

public final class MusicSourceRegistry: @unchecked Sendable {
    public static let shared = MusicSourceRegistry()

    public let players: [PlayerDescriptor] = [
        // 1. Native AppleScript / DistributedNotification Players (Highest fidelity)
        PlayerDescriptor(
            id: "com.spotify.client",
            displayName: "Spotify",
            category: .native,
            alternateBundleIDs: [],
            driver: .spotify,
            priority: 100,
            audioHelperPrefixes: ["com.spotify.client"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "com.apple.Music",
            displayName: "Apple Music",
            category: .native,
            alternateBundleIDs: ["com.apple.iTunes"],
            driver: .appleMusic,
            priority: 98,
            audioHelperPrefixes: ["com.apple.Music"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "com.swinsian.Swinsian",
            displayName: "Swinsian",
            category: .native,
            alternateBundleIDs: [],
            driver: .swinsian,
            priority: 94,
            audioHelperPrefixes: ["com.swinsian.Swinsian"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "com.coppertino.Vox",
            displayName: "VOX",
            category: .native,
            alternateBundleIDs: ["com.coppertino.VoxCloud"],
            driver: .vox,
            priority: 92,
            audioHelperPrefixes: ["com.coppertino.Vox"],
            supportsWindowTitleFallback: false
        ),

        // 2. Desktop Streaming Apps (Local API + MediaRemote + Window/Audio Fallback)
        PlayerDescriptor(
            id: "com.github.th-ch.youtube-music",
            displayName: "YouTube Music",
            category: .desktopStreaming,
            alternateBundleIDs: [
                "dev.pear.youtube-music",
                "com.electron.youtube-music",
                "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod"
            ],
            driver: .pearYTM(port: 26538),
            priority: 90,
            audioHelperPrefixes: ["com.github.th-ch.youtube-music", "dev.pear.youtube-music"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "app.ytmdesktop.ytmdesktop",
            displayName: "YTMDesktop",
            category: .desktopStreaming,
            alternateBundleIDs: ["ytmdesktop"],
            driver: .ytmDesktop(port: 9863),
            priority: 89,
            audioHelperPrefixes: ["app.ytmdesktop.ytmdesktop"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "sh.cider.electron",
            displayName: "Cider",
            category: .desktopStreaming,
            alternateBundleIDs: ["sh.cider.cider", "com.cidercollective.cider", "sh.cider.Cider"],
            driver: .cider(port: 10767),
            priority: 88,
            audioHelperPrefixes: ["sh.cider", "com.cidercollective"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "com.tidal.desktop",
            displayName: "TIDAL",
            category: .desktopStreaming,
            alternateBundleIDs: ["com.tidal.TIDAL"],
            driver: .windowAndAudio,
            priority: 86,
            audioHelperPrefixes: ["com.tidal.desktop", "com.tidal.TIDAL"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "com.deezer.deezer-desktop",
            displayName: "Deezer",
            category: .desktopStreaming,
            alternateBundleIDs: ["com.deezer.Deezer"],
            driver: .windowAndAudio,
            priority: 85,
            audioHelperPrefixes: ["com.deezer"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "com.qobuz.Qobuz",
            displayName: "Qobuz",
            category: .desktopStreaming,
            alternateBundleIDs: ["com.qobuz.desktop"],
            driver: .windowAndAudio,
            priority: 84,
            audioHelperPrefixes: ["com.qobuz"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "com.amazon.music",
            displayName: "Amazon Music",
            category: .desktopStreaming,
            alternateBundleIDs: ["com.amazon.Amazon-Music"],
            driver: .windowAndAudio,
            priority: 83,
            audioHelperPrefixes: ["com.amazon.music", "com.amazon.Amazon-Music"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "com.soundcloud.desktop",
            displayName: "SoundCloud",
            category: .desktopStreaming,
            alternateBundleIDs: [],
            driver: .windowAndAudio,
            priority: 82,
            audioHelperPrefixes: ["com.soundcloud"],
            supportsWindowTitleFallback: true
        ),

        // 3. Local & Hi-Res Media Players
        PlayerDescriptor(
            id: "org.videolan.vlc",
            displayName: "VLC",
            category: .mediaPlayer,
            alternateBundleIDs: [],
            driver: .vlc,
            priority: 76,
            audioHelperPrefixes: ["org.videolan.vlc"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "com.brushedtype.doppler-macos",
            displayName: "Doppler",
            category: .mediaPlayer,
            alternateBundleIDs: [],
            driver: .windowAndAudio,
            priority: 75,
            audioHelperPrefixes: ["com.brushedtype.doppler"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "org.cogx.cog",
            displayName: "Cog",
            category: .mediaPlayer,
            alternateBundleIDs: [],
            driver: .windowAndAudio,
            priority: 74,
            audioHelperPrefixes: ["org.cogx.cog"],
            supportsWindowTitleFallback: true
        ),
        PlayerDescriptor(
            id: "com.colliderli.iina",
            displayName: "IINA",
            category: .mediaPlayer,
            alternateBundleIDs: [],
            driver: .windowAndAudio,
            priority: 72,
            audioHelperPrefixes: ["com.colliderli.iina"],
            supportsWindowTitleFallback: true
        ),

        // 4. Web Browsers (YouTube Music, Spotify Web, SoundCloud, Apple Music Web, TIDAL Web, Deezer, Bandcamp...)
        PlayerDescriptor(
            id: "com.apple.Safari",
            displayName: "Safari",
            category: .browser,
            alternateBundleIDs: ["com.apple.SafariTechnologyPreview"],
            driver: .safariBrowser,
            priority: 60,
            audioHelperPrefixes: ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent", "com.apple.Safari"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "com.google.Chrome",
            displayName: "Google Chrome",
            category: .browser,
            alternateBundleIDs: ["com.google.Chrome.canary", "com.google.Chrome.beta"],
            driver: .chromiumBrowser,
            priority: 59,
            audioHelperPrefixes: ["com.google.Chrome"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "com.brave.Browser",
            displayName: "Brave Browser",
            category: .browser,
            alternateBundleIDs: ["com.brave.Browser.beta", "com.brave.Browser.nightly"],
            driver: .chromiumBrowser,
            priority: 58,
            audioHelperPrefixes: ["com.brave.Browser"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "company.thebrowser.Browser",
            displayName: "Arc",
            category: .browser,
            alternateBundleIDs: [],
            driver: .chromiumBrowser,
            priority: 57,
            audioHelperPrefixes: ["company.thebrowser.Browser"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "com.microsoft.edgemac",
            displayName: "Microsoft Edge",
            category: .browser,
            alternateBundleIDs: ["com.microsoft.edgemac.Beta"],
            driver: .chromiumBrowser,
            priority: 56,
            audioHelperPrefixes: ["com.microsoft.edgemac"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "com.vivaldi.Vivaldi",
            displayName: "Vivaldi",
            category: .browser,
            alternateBundleIDs: [],
            driver: .chromiumBrowser,
            priority: 55,
            audioHelperPrefixes: ["com.vivaldi.Vivaldi"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "com.operasoftware.Opera",
            displayName: "Opera",
            category: .browser,
            alternateBundleIDs: ["com.operasoftware.OperaGX"],
            driver: .chromiumBrowser,
            priority: 54,
            audioHelperPrefixes: ["com.operasoftware.Opera"],
            supportsWindowTitleFallback: false
        ),
        PlayerDescriptor(
            id: "org.mozilla.firefox",
            displayName: "Firefox",
            category: .browser,
            alternateBundleIDs: ["org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen"],
            driver: .windowAndAudio,
            priority: 50,
            audioHelperPrefixes: ["org.mozilla.firefox", "org.mozilla.plugincontainer", "app.zen-browser.zen"],
            supportsWindowTitleFallback: true
        ),
    ]

    private let lock = NSLock()
    private var cachedInstalled: [PlayerDescriptor]?
    private var lastDiscoveryDate: Date = .distantPast

    private init() {}

    public func canonicalDescriptor(forBundleID bundleID: String) -> PlayerDescriptor? {
        guard !bundleID.isEmpty else { return nil }
        if let direct = players.first(where: { $0.matches(bundleID: bundleID) }) {
            return direct
        }
        let lower = bundleID.lowercased()
        for player in players {
            if player.audioHelperPrefixes.contains(where: { lower.hasPrefix($0.lowercased()) }) {
                return player
            }
        }
        return nil
    }

    public func displayName(forBundleID bundleID: String) -> String {
        if let desc = canonicalDescriptor(forBundleID: bundleID) {
            return desc.displayName
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.isEmpty ? "Music Player" : bundleID
    }

    public func isKnownBundleID(_ bundleID: String) -> Bool {
        canonicalDescriptor(forBundleID: bundleID) != nil
    }

    public func installedPlayers(forceRefresh: Bool = false) -> [PlayerDescriptor] {
        lock.lock()
        if !forceRefresh, let cached = cachedInstalled, Date().timeIntervalSince(lastDiscoveryDate) < 30.0 {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let ws = NSWorkspace.shared
        let found = players.filter { desc in
            desc.allBundleIDs.contains { bid in
                ws.urlForApplication(withBundleIdentifier: bid) != nil
            }
        }

        lock.lock()
        cachedInstalled = found
        lastDiscoveryDate = Date()
        lock.unlock()
        return found
    }

    public func runningApp(for descriptor: PlayerDescriptor) -> NSRunningApplication? {
        for bid in descriptor.allBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first(where: { !$0.isTerminated }) {
                return app
            }
        }
        return nil
    }

    public func isRunning(_ descriptor: PlayerDescriptor) -> Bool {
        runningApp(for: descriptor) != nil
    }

    public func runningPlayers() -> [(descriptor: PlayerDescriptor, app: NSRunningApplication)] {
        var result: [(PlayerDescriptor, NSRunningApplication)] = []
        for desc in players {
            if let app = runningApp(for: desc) {
                result.append((desc, app))
            }
        }
        return result
    }
}
