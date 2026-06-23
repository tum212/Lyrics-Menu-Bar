import Foundation
import Combine



public struct LyricLine: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let time: TimeInterval
    public let text: String
    
    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

public final class LyricsService: ObservableObject, @unchecked Sendable {
    @Published public var lyrics: [LyricLine] = []
    @Published public var isLoading: Bool = false
    @Published public var error: Error?
    
    private var lastQuery: String = ""
    private var currentRequestID: Int = 0
    private var cache: [String: [LyricLine]] = [:]
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        return URLSession(configuration: config, delegate: SSLBypassDelegate(), delegateQueue: nil)
    }()
    
    public init() {}
    
    // MARK: - Public Entry Point
    public func fetchLyrics(trackName: String, artistName: String, albumName: String) {
        guard !trackName.isEmpty, !artistName.isEmpty else { return }
        
        let currentQuery = "\(trackName)-\(artistName)-\(albumName)"
        guard currentQuery != lastQuery else { return }
        
        self.lastQuery = currentQuery
        
        // Increment request ID — any in-flight request with an older ID will be discarded
        currentRequestID += 1
        let myRequestID = currentRequestID
        
        // 1. Check Cache
        if let cached = cache[currentQuery] {
            self.lyrics = cached
            self.isLoading = false
            return
        }
        
        self.lyrics = []
        self.isLoading = true
        
        // Clean track name (remove "- Remastered", "(feat. X)", "(Live)", etc.)
        var cleanName = trackName
        if let r = cleanName.range(of: " - ") { cleanName = String(cleanName[..<r.lowerBound]) }
        if let r = cleanName.range(of: " (") { cleanName = String(cleanName[..<r.lowerBound]) }
        cleanName = cleanName.trimmingCharacters(in: .whitespaces)
        
        fetchChain(cleanTrack: cleanName, originalTrack: trackName, artist: artistName, album: albumName, queryKey: currentQuery, requestID: myRequestID)
    }
    
    private func fetchChain(cleanTrack: String, originalTrack: String, artist: String, album: String, queryKey: String, requestID: Int) {
        Task { @MainActor in
            // Helper: check if this request is still valid before committing
            func isValid() -> Bool { return self.currentRequestID == requestID }
            
            // Phase 1: Race LRCLib sources concurrently (Instant!)
            let lrcResult: [LyricLine] = await withTaskGroup(of: (Int, [LyricLine]).self) { group in
                group.addTask { (0, await self.lrclibGet(track: cleanTrack, artist: artist, album: album)) }
                group.addTask { (1, await self.lrclibSearch(query: "\(cleanTrack) \(artist)")) }
                group.addTask { (2, await self.lrclibSearch(query: "\(originalTrack) \(artist)")) }
                
                var collected: [Int: [LyricLine]] = [:]
                for await (index, lines) in group {
                    if !lines.isEmpty {
                        collected[index] = lines
                        // If it's synced, we take it immediately!
                        if lines.count > 1 && lines.last!.time > 0 {
                            group.cancelAll()
                            return lines
                        }
                    }
                }
                // Fallback to best available if none were synced
                if let best = collected[0], !best.isEmpty { return best }
                if let best = collected[1], !best.isEmpty { return best }
                if let best = collected[2], !best.isEmpty { return best }
                return []
            }
            
            guard isValid() else { return }
            
            if !lrcResult.isEmpty {
                self.lyrics = lrcResult
                self.cache[queryKey] = lrcResult
                self.isLoading = false
                return
            }
            
            // Phase 2: Race OVH sources concurrently if LRCLib failed
            let ovhResult: [LyricLine] = await withTaskGroup(of: (Int, [LyricLine]).self) { group in
                group.addTask { (0, await self.ovhFetch(track: cleanTrack, artist: artist)) }
                group.addTask { (1, await self.ovhFetch(track: originalTrack, artist: artist)) }
                
                for await (_, lines) in group {
                    if !lines.isEmpty {
                        group.cancelAll()
                        return lines
                    }
                }
                return []
            }
            
            guard isValid() else { return }
            self.lyrics = ovhResult
            self.cache[queryKey] = ovhResult
            self.isLoading = false
        }
    }
    
    // MARK: - Source 1 & 3: LRCLib Search API (returns synced > plain)
    private func lrclibSearch(query: String) async -> [LyricLine] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&?=/")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlStr = "https://lrclib.net/api/search?q=\(encoded)"
        guard let url = URL(string: urlStr) else { return [] }
        
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                print("LRCLib Search failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return []
            }
            struct LRCResult: Decodable { let syncedLyrics: String?; let plainLyrics: String? }
            let results = try JSONDecoder().decode([LRCResult].self, from: data)
            // Pick first result that has syncedLyrics, then plain
            if let synced = results.first(where: { $0.syncedLyrics?.isEmpty == false }) {
                return parseLRC(synced.syncedLyrics!)
            }
            if let plain = results.first(where: { $0.plainLyrics?.isEmpty == false }) {
                return parsePlain(plain.plainLyrics!)
            }
        } catch {
            print("LRCLib Search error: \(error)")
        }
        return []
    }
    
    // MARK: - Source 2: LRCLib Get API (direct match endpoint)
    private func lrclibGet(track: String, artist: String, album: String) async -> [LyricLine] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&?=/")
        let tEnc = track.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let aEnc = artist.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let alEnc = album.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlStr = "https://lrclib.net/api/get?track_name=\(tEnc)&artist_name=\(aEnc)&album_name=\(alEnc)"
        guard let url = URL(string: urlStr) else { return [] }
        
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                print("LRCLib Get failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return [] 
            }
            struct LRCResult: Decodable { let syncedLyrics: String?; let plainLyrics: String? }
            let result = try JSONDecoder().decode(LRCResult.self, from: data)
            if let synced = result.syncedLyrics, !synced.isEmpty { return parseLRC(synced) }
            if let plain = result.plainLyrics, !plain.isEmpty { return parsePlain(plain) }
        } catch {
            print("LRCLib Get error: \(error)")
        }
        return []
    }
    
    // MARK: - Source 4 & 5: lyrics.ovh (unsynced)
    private func ovhFetch(track: String, artist: String) async -> [LyricLine] {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "+&?=/")
        let aEnc = artist.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let tEnc = track.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlStr = "https://api.lyrics.ovh/v1/\(aEnc)/\(tEnc)"
        guard let url = URL(string: urlStr) else { return [] }
        
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                print("OVH Fetch failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return [] 
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               var text = json["lyrics"] as? String {
                // Remove OVH french disclaimer header
                if text.hasPrefix("Paroles de la chanson") {
                    for sep in ["\r\n\n", "\n\n"] {
                        if let r = text.range(of: sep) { text = String(text[r.upperBound...]); break }
                    }
                }
                return parsePlain(text)
            }
        } catch {
            print("OVH Fetch error: \(error)")
        }
        return []
    }
    
    // MARK: - Parsers
    private func parseLRC(_ lrc: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let pattern = "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\](.*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        for line in lrc.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let lastMatch = matches.last else { continue }
            
            var text = ""
            if let tr = Range(lastMatch.range(at: 3), in: line) {
                text = String(line[tr]).trimmingCharacters(in: .whitespaces)
            }
            
            for match in matches {
                if let mr = Range(match.range(at: 1), in: line),
                   let sr = Range(match.range(at: 2), in: line),
                   let min = Double(line[mr]),
                   let sec = Double(line[sr]) {
                    result.append(LyricLine(time: min * 60 + sec, text: text))
                }
            }
        }
        return result.sorted { $0.time < $1.time }
    }
    
    private func parsePlain(_ text: String) -> [LyricLine] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.map { LyricLine(time: 0, text: $0) }
    }
}

final class SSLBypassDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
