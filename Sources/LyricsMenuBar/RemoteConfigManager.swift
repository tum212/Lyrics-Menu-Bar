import Foundation
import Combine

public struct LyricsEndpointsConfig: Codable, Equatable, Sendable {
    public var lrclibSearch: String
    public var lrclibGet: String
    public var lyricsOvh: String

    enum CodingKeys: String, CodingKey {
        case lrclibSearch = "lrclib_search"
        case lrclibGet = "lrclib_get"
        case lyricsOvh = "lyrics_ovh"
    }
}

public struct AnnouncementConfig: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let message: String
    public let actionUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, title, message
        case actionUrl = "action_url"
    }
}

public struct RemoteConfig: Codable, Equatable, Sendable {
    public let version: String
    public let build: Int
    public let releaseDate: String?
    public let releaseNotes: String?
    public let downloadUrl: String?
    public let mandatory: Bool?
    public let lyricsEndpoints: LyricsEndpointsConfig?
    public let announcement: AnnouncementConfig?

    enum CodingKeys: String, CodingKey {
        case version, build
        case releaseDate = "release_date"
        case releaseNotes = "release_notes"
        case downloadUrl = "download_url"
        case mandatory
        case lyricsEndpoints = "lyrics_endpoints"
        case announcement
    }
}

@MainActor
public final class RemoteConfigManager: ObservableObject {
    public static let shared = RemoteConfigManager()

    public static let remoteConfigURL = URL(string: "https://raw.githubusercontent.com/tum212/Lyrics-Menu-Bar/main/remote_config.json")!
    private let cacheKey = "cached_remote_config"

    @Published public private(set) var config: RemoteConfig?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastFetchDate: Date?

    public nonisolated static var lrclibSearchEndpoint: String {
        UserDefaults.standard.string(forKey: "config_lrclib_search") ?? "https://lrclib.net/api/search"
    }

    public nonisolated static var lrclibGetEndpoint: String {
        UserDefaults.standard.string(forKey: "config_lrclib_get") ?? "https://lrclib.net/api/get"
    }

    public nonisolated static var lyricsOvhEndpoint: String {
        UserDefaults.standard.string(forKey: "config_lyrics_ovh") ?? "https://api.lyrics.ovh/v1"
    }

    public var lrclibSearchUrl: String {
        Self.lrclibSearchEndpoint
    }

    public var lrclibGetUrl: String {
        Self.lrclibGetEndpoint
    }

    public var lyricsOvhUrl: String {
        Self.lyricsOvhEndpoint
    }

    private init() {
        loadCachedConfig()
        Task {
            await fetchRemoteConfig()
        }
    }

    private func syncEndpointsToDefaults(_ cfg: RemoteConfig) {
        if let endpoints = cfg.lyricsEndpoints {
            UserDefaults.standard.set(endpoints.lrclibSearch, forKey: "config_lrclib_search")
            UserDefaults.standard.set(endpoints.lrclibGet, forKey: "config_lrclib_get")
            UserDefaults.standard.set(endpoints.lyricsOvh, forKey: "config_lyrics_ovh")
        }
    }

    private func loadCachedConfig() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }
        do {
            let decoded = try JSONDecoder().decode(RemoteConfig.self, from: data)
            self.config = decoded
            syncEndpointsToDefaults(decoded)
        } catch {
            print("RemoteConfigManager: Failed to decode cached config:", error)
        }
    }

    public func fetchRemoteConfig() async -> RemoteConfig? {
        isLoading = true
        defer { isLoading = false }

        do {
            var request = URLRequest(url: Self.remoteConfigURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
            request.setValue("LyricsMenuBar/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return self.config
            }

            let decoded = try JSONDecoder().decode(RemoteConfig.self, from: data)
            self.config = decoded
            syncEndpointsToDefaults(decoded)
            self.lastFetchDate = Date()
            UserDefaults.standard.set(data, forKey: cacheKey)
            return decoded
        } catch {
            print("RemoteConfigManager: Network fetch failed, using fallback/cached:", error)
            return self.config
        }
    }
}
