import Foundation
import Combine



public struct LyricWord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let index: Int
    
    public init(id: UUID = UUID(), text: String, startTime: TimeInterval, endTime: TimeInterval, index: Int) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.index = index
    }
}

public struct LyricLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let time: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let words: [LyricWord]
    
    public init(id: UUID = UUID(), time: TimeInterval, endTime: TimeInterval = 0, text: String, words: [LyricWord] = []) {
        self.id = id
        self.time = time
        self.endTime = endTime
        self.text = text
        self.words = words
    }
    
    public init(time: TimeInterval, text: String) {
        self.init(id: UUID(), time: time, endTime: 0, text: text, words: [])
    }
}

public enum LyricTimingCalculator {
    /// Estimates syllable count using phoneme-based linguistic rules
    public static func countSyllables(word: String) -> Int {
        let cleaned = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if cleaned.isEmpty { return 1 }
        if cleaned.count <= 3 { return 1 }
        
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0
        var prevWasVowel = false
        let chars = Array(cleaned)
        
        for char in chars {
            let isVowel = vowels.contains(char)
            if isVowel && !prevWasVowel {
                count += 1
            }
            prevWasVowel = isVowel
        }
        
        // Adjust for silent trailing 'e'
        if cleaned.hasSuffix("e") && !cleaned.hasSuffix("le") && count > 1 {
            let secondToLast = chars[chars.count - 2]
            if !vowels.contains(secondToLast) {
                count -= 1
            }
        }
        
        return max(1, count)
    }
    
    /// Assigns musical and phonetic weight to a word
    public static func wordWeight(word: String, isLastInLine: Bool) -> Double {
        let cleaned = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let syllables = countSyllables(word: cleaned)
        let charLen = cleaned.count
        
        let unstressed: Set<String> = [
            "a", "an", "the", "in", "on", "at", "to", "for", "of", "and", "or", "but",
            "is", "it", "my", "so", "up", "you", "me", "we", "he", "she", "i"
        ]
        
        var multiplier = 1.0
        if unstressed.contains(cleaned) {
            multiplier = 0.65
        }
        
        if word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix("-") || word.hasSuffix("—") {
            multiplier *= 1.30
        } else if word.hasSuffix("?") || word.hasSuffix("!") {
            multiplier *= 1.25
        }
        
        if isLastInLine {
            multiplier *= 1.75 // Pre-pausal lengthening / vocal sustain
        }
        
        let baseWeight = Double(syllables) * 0.70 + Double(charLen) * 0.08 + 0.22
        return baseWeight * multiplier
    }
    
    /// Computes mathematically balanced word-by-word timestamps for lines
    public static func computeWordTimings(for lines: [LyricLine], totalTrackDuration: Double = 0) -> [LyricLine] {
        guard !lines.isEmpty else { return [] }
        
        var computedLines: [LyricLine] = []
        
        for (i, line) in lines.enumerated() {
            if !line.words.isEmpty && line.endTime > line.time {
                computedLines.append(line)
                continue
            }
            
            let startTime = line.time
            let rawTokens = line.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            
            if rawTokens.isEmpty {
                computedLines.append(LyricLine(id: line.id, time: startTime, endTime: startTime + 1.0, text: line.text, words: []))
                continue
            }
            
            // Time gap to next line
            let nextStartTime: TimeInterval
            if i < lines.count - 1 {
                nextStartTime = lines[i + 1].time
            } else {
                let fallback = totalTrackDuration > startTime ? totalTrackDuration : startTime + 4.0
                nextStartTime = min(startTime + 6.0, fallback)
            }
            
            let rawGap = max(0.4, nextStartTime - startTime)
            
            // Vocal phonation time vs breath pause
            let totalSyllables = rawTokens.reduce(0) { $0 + countSyllables(word: $1) }
            let estSingingDuration = Double(totalSyllables) * 0.28 + 0.35
            
            let vocalDuration: Double
            if rawGap <= 1.8 {
                let breath = min(0.20, rawGap * 0.12)
                vocalDuration = max(0.25, rawGap - breath)
            } else if rawGap <= 6.0 {
                let breath = max(0.35, min(1.2, rawGap * 0.20))
                let target = max(estSingingDuration, rawGap - breath)
                vocalDuration = min(rawGap - 0.2, target)
            } else {
                // Long instrumental gap: end singing naturally
                vocalDuration = min(rawGap - 1.5, max(estSingingDuration * 1.25, 4.5))
            }
            
            let endTime = startTime + vocalDuration
            
            let weights = rawTokens.enumerated().map { idx, word in
                wordWeight(word: word, isLastInLine: idx == rawTokens.count - 1)
            }
            let totalWeight = max(0.001, weights.reduce(0, +))
            
            var words: [LyricWord] = []
            var currentWordStart = startTime
            
            for (idx, token) in rawTokens.enumerated() {
                let frac = weights[idx] / totalWeight
                let wordDuration = max(0.08, vocalDuration * frac)
                let wordEnd = (idx == rawTokens.count - 1) ? endTime : (currentWordStart + wordDuration)
                
                words.append(LyricWord(
                    text: token,
                    startTime: currentWordStart,
                    endTime: wordEnd,
                    index: idx
                ))
                currentWordStart = wordEnd
            }
            
            computedLines.append(LyricLine(
                id: line.id,
                time: startTime,
                endTime: endTime,
                text: line.text,
                words: words
            ))
        }
        
        return computedLines
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
        return URLSession(configuration: config, delegate: InsecureSessionDelegate(), delegateQueue: nil)
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
                group.addTask { (1, await self.lrclibSearch(query: "\(cleanTrack) \(artist)", expectedTrack: cleanTrack, expectedArtist: artist)) }
                group.addTask { (2, await self.lrclibSearch(query: "\(originalTrack) \(artist)", expectedTrack: originalTrack, expectedArtist: artist)) }
                
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
    
    private struct LRCResult: Decodable {
        let trackName: String?
        let artistName: String?
        let syncedLyrics: String?
        let plainLyrics: String?
    }
    
    private func isMatchingTrack(trackName: String?, artistName: String?, expectedTrack: String, expectedArtist: String) -> Bool {
        guard let t = trackName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              let a = artistName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        let expT = expectedTrack.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let expA = expectedArtist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        func simplify(_ s: String) -> String {
            return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "(", with: " ")
                    .replacingOccurrences(of: ")", with: " ")
                    .replacingOccurrences(of: ".", with: " ")
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let st = simplify(t), sa = simplify(a)
        let sExpT = simplify(expT), sExpA = simplify(expA)
        
        let artistMatches = sa == sExpA || sa.contains(sExpA) || sExpA.contains(sa)
        let trackMatches = st == sExpT || st.contains(sExpT) || sExpT.contains(st)
        
        return artistMatches && trackMatches
    }
    
    // MARK: - Source 1 & 3: LRCLib Search API (returns synced > plain)
    private func lrclibSearch(query: String, expectedTrack: String, expectedArtist: String) async -> [LyricLine] {
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
                throw URLError(.badServerResponse)
            }
            let results = try JSONDecoder().decode([LRCResult].self, from: data)
            let matched = results.filter { isMatchingTrack(trackName: $0.trackName, artistName: $0.artistName, expectedTrack: expectedTrack, expectedArtist: expectedArtist) }
            
            if let synced = matched.first(where: { $0.syncedLyrics?.isEmpty == false }) {
                return parseLRC(synced.syncedLyrics!)
            }
            if let plain = matched.first(where: { $0.plainLyrics?.isEmpty == false }) {
                return parsePlain(plain.plainLyrics!)
            }
        } catch {
            print("LRCLib Search URLSession failed: \(error). Falling back to curl...")
            if let output = try? await runCurl(urlStr) {
                if let data = output.data(using: .utf8),
                   let results = try? JSONDecoder().decode([LRCResult].self, from: data) {
                    let matched = results.filter { isMatchingTrack(trackName: $0.trackName, artistName: $0.artistName, expectedTrack: expectedTrack, expectedArtist: expectedArtist) }
                    if let synced = matched.first(where: { $0.syncedLyrics?.isEmpty == false }) {
                        return parseLRC(synced.syncedLyrics!)
                    }
                    if let plain = matched.first(where: { $0.plainLyrics?.isEmpty == false }) {
                        return parsePlain(plain.plainLyrics!)
                    }
                }
            }
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
                throw URLError(.badServerResponse)
            }
            let result = try JSONDecoder().decode(LRCResult.self, from: data)
            if isMatchingTrack(trackName: result.trackName, artistName: result.artistName, expectedTrack: track, expectedArtist: artist) {
                if let synced = result.syncedLyrics, !synced.isEmpty { return parseLRC(synced) }
                if let plain = result.plainLyrics, !plain.isEmpty { return parsePlain(plain) }
            }
        } catch {
            print("LRCLib Get URLSession failed: \(error). Falling back to curl...")
            if let output = try? await runCurl(urlStr) {
                if let data = output.data(using: .utf8),
                   let result = try? JSONDecoder().decode(LRCResult.self, from: data) {
                    if isMatchingTrack(trackName: result.trackName, artistName: result.artistName, expectedTrack: track, expectedArtist: artist) {
                        if let synced = result.syncedLyrics, !synced.isEmpty { return parseLRC(synced) }
                        if let plain = result.plainLyrics, !plain.isEmpty { return parsePlain(plain) }
                    }
                }
            }
        }
        return []
    }
    
    private func runCurl(_ urlString: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-k", "-s", "-m", "10",
                "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                urlString]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile() // Read BEFORE waitUntilExit to prevent deadlock
                process.waitUntilExit()
                if let output = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: URLError(.cannotDecodeContentData))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
        
        for rawLine in lrc.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
            guard let lastMatch = matches.last else { continue }
            
            var lineContent = ""
            if let tr = Range(lastMatch.range(at: 3), in: rawLine) {
                lineContent = String(rawLine[tr]).trimmingCharacters(in: .whitespaces)
            }
            
            let elrcData = parseELRCLine(content: lineContent)
            let cleanText = elrcData?.text ?? lineContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            
            for match in matches {
                if let mr = Range(match.range(at: 1), in: rawLine),
                   let sr = Range(match.range(at: 2), in: rawLine),
                   let min = Double(rawLine[mr]),
                   let sec = Double(rawLine[sr]) {
                    let lineTime = min * 60.0 + sec
                    if let words = elrcData?.words, !words.isEmpty {
                        let lineEnd = words.last?.endTime ?? (lineTime + 3.0)
                        result.append(LyricLine(time: lineTime, endTime: lineEnd, text: cleanText, words: words))
                    } else {
                        result.append(LyricLine(time: lineTime, text: cleanText))
                    }
                }
            }
        }
        
        let sorted = result.sorted { $0.time < $1.time }
        return LyricTimingCalculator.computeWordTimings(for: sorted)
    }
    
    private func parseELRCLine(content: String) -> (text: String, words: [LyricWord])? {
        let pattern = "<(\\d+):(\\d+(?:\\.\\d+)?)>([^<]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        
        var words: [LyricWord] = []
        var fullText = ""
        
        for (i, match) in matches.enumerated() {
            guard let mr = Range(match.range(at: 1), in: content),
                  let sr = Range(match.range(at: 2), in: content),
                  let tr = Range(match.range(at: 3), in: content),
                  let min = Double(content[mr]),
                  let sec = Double(content[sr]) else { continue }
            
            let wordStart = min * 60.0 + sec
            let rawToken = String(content[tr])
            let trimmed = rawToken.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            let nextWordStart: TimeInterval
            if i < matches.count - 1,
               let nmr = Range(matches[i + 1].range(at: 1), in: content),
               let nsr = Range(matches[i + 1].range(at: 2), in: content),
               let nmin = Double(content[nmr]),
               let nsec = Double(content[nsr]) {
                nextWordStart = nmin * 60.0 + nsec
            } else {
                nextWordStart = wordStart + 0.8
            }
            
            // Check if this token belongs to the previous word (syllable continuation)
            let isContinuation = !words.isEmpty && !rawToken.hasPrefix(" ") && !fullText.hasSuffix(" ")
            if isContinuation {
                let last = words.removeLast()
                words.append(LyricWord(
                    id: last.id,
                    text: last.text + trimmed,
                    startTime: last.startTime,
                    endTime: max(last.endTime, max(wordStart + 0.1, nextWordStart)),
                    index: last.index
                ))
            } else {
                words.append(LyricWord(
                    text: trimmed,
                    startTime: wordStart,
                    endTime: max(wordStart + 0.1, nextWordStart),
                    index: words.count
                ))
            }
            fullText += rawToken
        }
        
        return words.isEmpty ? nil : (fullText.trimmingCharacters(in: .whitespaces), words)
    }
    
    private func parsePlain(_ text: String) -> [LyricLine] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.map { LyricLine(time: 0, text: $0) }
    }
}

final class InsecureSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
