import AppKit
import Foundation

// MARK: - Artwork State
public enum ArtworkState: Equatable, Sendable {
    case idle
    case loading(trackId: String)
    case loaded(trackId: String)
    case failed(trackId: String, error: String)
}

// MARK: - Swift 6 Thread-Safe Artwork Cache
@MainActor
public final class ArtworkCache {
    public static let shared = ArtworkCache()
    
    private let cache = NSCache<NSString, NSImage>()
    
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 60 * 1024 * 1024 // 60MB
    }
    
    public func image(forKey key: String) -> NSImage? {
        return cache.object(forKey: key as NSString)
    }
    
    public func setImage(_ image: NSImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
    
    public func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }
    
    public static func cacheKey(for track: MusicTrack) -> String {
        let nameKey = track.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let artistKey = track.artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(track.source.rawValue)|\(nameKey)|\(artistKey)"
    }
    
    public static func normalizeKey(name: String, artist: String) -> String {
        let nameKey = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let artistKey = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(nameKey)|\(artistKey)"
    }
    
    public func storeImage(_ image: NSImage, for track: MusicTrack) {
        setImage(image, forKey: track.id)
        setImage(image, forKey: ArtworkCache.cacheKey(for: track))
        setImage(image, forKey: ArtworkCache.normalizeKey(name: track.name, artist: track.artist))
    }
    
    public func findImage(for track: MusicTrack) -> NSImage? {
        return image(forKey: track.id)
            ?? image(forKey: ArtworkCache.cacheKey(for: track))
            ?? image(forKey: ArtworkCache.normalizeKey(name: track.name, artist: track.artist))
    }
    
    public func clear() {
        cache.removeAllObjects()
    }
}

// MARK: - Artwork URL Sanitizer & Loader
@MainActor
public enum ArtworkLoader {
    
    /// Normalizes and validates artwork URLs:
    /// - Converts internal `spotify:image:<hash>` URIs to `https://i.scdn.co/image/<hash>`
    /// - Validates `http` and `https` schemes
    public static func sanitizeArtworkURL(_ urlString: String?) -> URL? {
        guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty else {
            return nil
        }
        
        // Handle Spotify internal URI format (e.g. spotify:image:ab67616d0000b273...)
        if urlString.hasPrefix("spotify:image:") {
            let hash = String(urlString.dropFirst("spotify:image:".count))
            if !hash.isEmpty {
                return URL(string: "https://i.scdn.co/image/\(hash)")
            }
        }
        
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        
        return url
    }
    
    /// Asynchronously downloads and decodes an image on @MainActor with caching
    public static func fetchImage(from url: URL, cacheKey: String) async -> NSImage? {
        if let cached = ArtworkCache.shared.image(forKey: cacheKey) {
            return cached
        }
        
        do {
            var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            guard !data.isEmpty, let image = NSImage(data: data) else {
                return nil
            }
            ArtworkCache.shared.setImage(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }
    
    /// Fallback fetcher: Searches Apple Music / iTunes Search API for high-resolution cover art (600x600)
    /// Strict validation ensures artists and track names genuinely match, preventing wrong-artwork hijacking.
    public static func fetchArtworkFromITunes(trackName: String, artistName: String, cacheKey: String) async -> NSImage? {
        if let cached = ArtworkCache.shared.image(forKey: cacheKey) {
            return cached
        }
        
        let cleanedTrack = trackName
            .replacingOccurrences(of: "(feat.*)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "- Remaster.*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTerm = "\(artistName) \(cleanedTrack)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(queryTerm)&entity=song&limit=5") else {
            return nil
        }
        
        do {
            var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6)
            req.setValue("LyricsMenuBar/1.3", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]] {
                let targetArtist = artistName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let targetTrack = cleanedTrack.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                
                for item in results {
                    guard let itemArtist = (item["artistName"] as? String)?.lowercased(),
                          let itemTrack = (item["trackName"] as? String)?.lowercased() else { continue }
                    
                    let artistMatch = itemArtist.contains(targetArtist) || targetArtist.contains(itemArtist)
                    let trackMatch = itemTrack.contains(targetTrack) || targetTrack.contains(itemTrack)
                    guard artistMatch && trackMatch else { continue }
                    
                    if let art100 = item["artworkUrl100"] as? String {
                        let highResArt = art100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                        if let artUrl = URL(string: highResArt) {
                            return await fetchImage(from: artUrl, cacheKey: cacheKey)
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
