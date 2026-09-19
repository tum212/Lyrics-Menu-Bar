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
        cache.countLimit = 150
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
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
        let sanitized = ArtworkLoader.sanitizeArtworkURL(track.artworkURL)?.absoluteString ?? "raw"
        return "\(track.source.rawValue)|\(track.id)|\(sanitized)"
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
            let (data, response) = try await URLSession.shared.data(from: url)
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
}
