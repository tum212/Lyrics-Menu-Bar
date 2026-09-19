import SwiftUI
import AppKit

// MARK: - Native Optical Liquid Glass (Control Center Material)
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Main View
struct ContentView: View {
    @ObservedObject var musicService: MusicService
    @ObservedObject var lyricsService: LyricsService
    @ObservedObject var audioAnalyzer: AudioAnalyzer

    // Backward-compatibility alias
    private var spotify: MusicService { musicService }

    @Environment(\.colorScheme) var colorScheme

    // Track which lyric index is active for scroll animation
    @State private var displayedIndex: Int = 0
    @State private var isLyricsHovered: Bool = false
    
    // User preferences
    @AppStorage("showLyrics") private var showLyrics = true
    @AppStorage("waveformBars") private var waveformBars = 14
    @AppStorage("showAlbumArt") private var showAlbumArt = true
    @AppStorage("hapticEnabled") private var hapticEnabled = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Unified single-piece Optical Liquid Glass surface (Control Center Refraction)
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow, state: .active)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.25),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )

            // Single unified content container - NO inner cards
            HStack(spacing: 20) {
                // MARK: Left Column - Player Info (130pt)
                VStack(spacing: 0) {
                    // Album Art
                    Group {
                        if let image = musicService.artworkImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            placeholderArt
                        }
                    }
                    .frame(width: 116, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 4)

                    Spacer().frame(height: 10)

                    // Track Info
                    Text(musicService.currentTrack?.name ?? "No Music Playing")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 130, alignment: .center)

                    Text(musicService.currentTrack?.artist ?? "Open Spotify or Apple Music")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 130, alignment: .center)

                    Spacer().frame(height: 10)

                    // Playback Controls
                    HStack(spacing: 16) {
                        Button(action: { musicService.previousTrack() }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle()).focusable(false)

                        Button(action: { musicService.playPause() }) {
                            Image(systemName: musicService.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .frame(width: 24)
                        }
                        .buttonStyle(PlainButtonStyle()).focusable(false)

                        Button(action: { musicService.nextTrack() }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle()).focusable(false)
                    }
                }
                .frame(width: 130)
                Spacer().frame(width: 4)

                // MARK: Right Column - Continuous Lyrics Stream
                TimelineView(.animation) { timeline in
                    lyricsPanel(currentDate: timeline.date)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 480, height: 240)

            // Top Right Controls (Glass Buttons)
            HStack(spacing: 8) {
                NativeSettingsMenu()
                    .frame(width: 26, height: 26)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                    .menuIndicator(.hidden)
                    .fixedSize()

                Button(action: { NotificationCenter.default.post(name: Notification.Name("ClosePopover"), object: nil) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(PlainButtonStyle())
                .focusable(false)
            }
            .padding([.top, .trailing], 14)
        }
        .onChange(of: musicService.currentTrack?.id) { [musicService] _ in
            LyricLineLayoutCache.shared.clear()
            if let track = musicService.currentTrack {
                lyricsService.fetchLyrics(trackName: track.name, artistName: track.artist, albumName: track.album)
            } else {
                lyricsService.lyrics = []
            }
            displayedIndex = 0
        }
        .onChange(of: lyricsService.lyrics.count) { _ in
            LyricLineLayoutCache.shared.clear()
        }
        .onChange(of: musicService.isPlaying) { isPlaying in
            if isPlaying && waveformBars > 0 && UserDefaults.standard.bool(forKey: "audioFeaturesEnabled") {
                audioAnalyzer.start()
            } else {
                audioAnalyzer.stop()
            }
        }
        .onAppear {
            if musicService.isPlaying && waveformBars > 0 && UserDefaults.standard.bool(forKey: "audioFeaturesEnabled") {
                audioAnalyzer.start()
            } else {
                audioAnalyzer.stop()
            }
        }
        .onDisappear {
            if waveformBars == 0 {
                audioAnalyzer.stop()
            }
        }
        .background(Color.clear)
    }

    // MARK: - Lyrics Panel with Apple Music style scroll & Click-to-Seek
    @ViewBuilder
    private func lyricsPanel(currentDate: Date) -> some View {
        let info = getActiveLyricsInfo(currentDate: currentDate)
        let allLyrics = lyricsService.lyrics

        if allLyrics.isEmpty {
            Text(lyricsService.isLoading ? "Loading lyrics..." : (spotify.isPlaying ? "♪" : ""))
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            let activeIdx = allLyrics.firstIndex(where: { $0.id == info.activeId }) ?? 0

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(allLyrics.enumerated()), id: \.element.id) { idx, line in
                            let isActive = line.id == info.activeId
                            let isPast = idx < activeIdx

                            LyricLineRowView(
                                line: line,
                                isActive: isActive,
                                isPast: isPast,
                                isLyricsHovered: isLyricsHovered,
                                currentTime: info.currentTime,
                                fallbackProgress: info.progress,
                                isUnsynced: info.isUnsynced,
                                onSeek: {
                                    let seekTime: TimeInterval
                                    if line.time > 0 {
                                        seekTime = line.time
                                    } else {
                                        let duration = spotify.currentTrack?.duration ?? 180.0
                                        seekTime = (Double(idx) / Double(max(1, allLyrics.count))) * duration
                                    }
                                    spotify.seek(to: seekTime)
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                                }
                            )
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
                }
                .onHover { hovering in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isLyricsHovered = hovering
                    }
                }
                // Apple Music style: scroll current line smoothly to ~35% from top
                .onChange(of: info.activeId) { [proxy] newId in
                    if let id = newId {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                            proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.35))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Fade mask top & bottom for Apple Music feel
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func getActiveLyricsInfo(currentDate: Date) -> (lines: [LyricLine], progress: Double, activeId: UUID?, activeLine: LyricLine?, currentTime: TimeInterval, isUnsynced: Bool) {
        let time = spotify.currentTime

        let allLyrics = lyricsService.lyrics
        if allLyrics.isEmpty { return ([], 0.0, nil, nil, time, false) }

        let isUnsynced = allLyrics.count > 1 && allLyrics.last!.time == 0
        var currentIndex = 0
        var progress = 0.0

        if isUnsynced {
            let duration = spotify.currentTrack?.duration ?? 100.0
            progress = max(0, min(1, time / duration))
            currentIndex = Int(progress * Double(allLyrics.count))
            if currentIndex >= allLyrics.count { currentIndex = allLyrics.count - 1 }
            progress = 1.0
            let line = allLyrics[currentIndex]
            return (allLyrics, progress, line.id, line, time, true)
        } else {
            // Check if song is still in intro before vocals begin
            if let firstTime = allLyrics.first?.time, time < firstTime {
                return (allLyrics, 0.0, nil, nil, time, false)
            }
            
            for (index, line) in allLyrics.enumerated() {
                if line.time <= time { currentIndex = index } else { break }
            }
            let activeLine = allLyrics[currentIndex]
            if currentIndex < allLyrics.count - 1 {
                let currentStart = activeLine.time
                let nextStart = allLyrics[currentIndex + 1].time
                let lineDuration = max(0.1, nextStart - currentStart)
                progress = max(0, min(1, (time - currentStart) / lineDuration))
            } else {
                progress = 1.0
            }
            return (allLyrics, progress, activeLine.id, activeLine, time, false)
        }
    }
}

// MARK: - Zero-Cost Main Thread Layout Cache (Eliminates frame stutters at 60 FPS)
@MainActor
final class LyricLineLayoutCache {
    static let shared = LyricLineLayoutCache()
    private var wordsCache: [UUID: [[LyricWord]]] = [:]
    private var linesCache: [UUID: [String]] = [:]
    
    func wrappedWords(for line: LyricLine, width: CGFloat, font: NSFont) -> [[LyricWord]] {
        if let cached = wordsCache[line.id] { return cached }
        let result = computeWrappedWords(words: line.words, width: width, font: font)
        wordsCache[line.id] = result
        return result
    }
    
    func wrappedLines(for line: LyricLine, width: CGFloat, font: NSFont) -> [String] {
        if let cached = linesCache[line.id] { return cached }
        let result = computeWrappedLines(text: line.text, width: width, font: font)
        linesCache[line.id] = result
        return result
    }
    
    func clear() {
        wordsCache.removeAll(keepingCapacity: true)
        linesCache.removeAll(keepingCapacity: true)
    }
    
    private func computeWrappedWords(words: [LyricWord], width: CGFloat, font: NSFont) -> [[LyricWord]] {
        var lines: [[LyricWord]] = []
        var currentLine: [LyricWord] = []
        var currentLineWidth: CGFloat = 0
        let spaceWidth = " ".size(withAttributes: [.font: font]).width
        let safeWidth = max(width - 12.0, 80.0)
        
        for word in words {
            let wordWidth = word.text.size(withAttributes: [.font: font]).width
            let addedWidth = currentLine.isEmpty ? wordWidth : (spaceWidth + wordWidth)
            
            if currentLineWidth + addedWidth > safeWidth && !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = [word]
                currentLineWidth = wordWidth
            } else {
                currentLine.append(word)
                currentLineWidth += addedWidth
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        return lines.isEmpty ? [words] : lines
    }
    
    private func computeWrappedLines(text: String, width: CGFloat, font: NSFont) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        var lines: [String] = []
        var currentLine = ""
        let safeWidth = max(width - 12.0, 80.0)
        
        for word in words {
            let testLine = currentLine.isEmpty ? String(word) : "\(currentLine) \(word)"
            let size = testLine.size(withAttributes: [.font: font])
            if size.width > safeWidth && !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = String(word)
            } else {
                currentLine = testLine
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        return lines.isEmpty ? [text] : lines
    }
}

// MARK: - Unified Lyric Line Row (Apple Music Karaoke + Single-Line + Click-to-Seek)
struct LyricLineRowView: View {
    let line: LyricLine
    let isActive: Bool
    let isPast: Bool
    let isLyricsHovered: Bool
    let currentTime: TimeInterval
    let fallbackProgress: Double
    let isUnsynced: Bool
    let onSeek: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        let isBgVocal = line.isBackgroundVocal
        let fontSize: CGFloat = isBgVocal ? 15 : 20
        let fontWeight: Font.Weight = isBgVocal ? .semibold : .bold
        let font = NSFont.systemFont(ofSize: fontSize, weight: isBgVocal ? .semibold : .bold)
        let containerWidth: CGFloat = 260.0
        let effectiveHover = isHovered || isLyricsHovered
        
        Group {
            if isUnsynced {
                unsyncedView(containerWidth: containerWidth, font: font, fontSize: fontSize, fontWeight: fontWeight, isBgVocal: isBgVocal)
            } else if !line.words.isEmpty {
                wordKaraokeView(containerWidth: containerWidth, font: font, fontSize: fontSize, fontWeight: fontWeight, isBgVocal: isBgVocal)
            } else {
                fallbackWipeView(containerWidth: containerWidth, font: font, fontSize: fontSize, fontWeight: fontWeight, isBgVocal: isBgVocal)
            }
        }
        .padding(.leading, isBgVocal ? 24 : 0)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered && !isActive ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .blur(radius: (isActive || effectiveHover) ? 0 : 2.5)
        .opacity(isActive ? 1.0 : (effectiveHover ? 0.85 : (isPast ? 0.35 : 0.45)))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isLyricsHovered)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isActive)
        .onTapGesture {
            onSeek()
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
    
    @ViewBuilder
    private func unsyncedView(containerWidth: CGFloat, font: NSFont, fontSize: CGFloat, fontWeight: Font.Weight, isBgVocal: Bool) -> some View {
        let effectiveWidth = containerWidth - (isBgVocal ? 24 : 0)
        let lines = LyricLineLayoutCache.shared.wrappedLines(for: line, width: effectiveWidth, font: font)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<lines.count, id: \.self) { i in
                Text(lines[i])
                    .font(.system(size: fontSize, weight: fontWeight))
                    .italic(isBgVocal)
                    .foregroundColor(isActive ? .white : .white.opacity(isHovered ? 0.75 : (isPast ? 0.32 : 0.60)))
                    .shadow(color: isActive ? .white.opacity(0.40) : .clear, radius: 4)
                    .animation(.easeInOut(duration: 0.38), value: isActive)
                    .frame(height: isBgVocal ? 22 : 28, alignment: .leading)
            }
        }
        .frame(width: effectiveWidth, alignment: .leading)
    }
    
    @ViewBuilder
    private func wordKaraokeView(containerWidth: CGFloat, font: NSFont, fontSize: CGFloat, fontWeight: Font.Weight, isBgVocal: Bool) -> some View {
        let effectiveWidth = containerWidth - (isBgVocal ? 24 : 0)
        let wrappedLines = LyricLineLayoutCache.shared.wrappedWords(for: line, width: effectiveWidth, font: font)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<wrappedLines.count, id: \.self) { lineIdx in
                let rowWords = wrappedLines[lineIdx]
                HStack(spacing: 5) {
                    ForEach(rowWords) { word in
                        WordLyricItemView(
                            word: word,
                            isActive: isActive,
                            isPast: isPast,
                            isHovered: isHovered,
                            currentTime: currentTime,
                            fontSize: fontSize,
                            fontWeight: fontWeight,
                            isItalic: isBgVocal
                        )
                    }
                }
            }
        }
        .frame(width: effectiveWidth, alignment: .leading)
    }
    
    @ViewBuilder
    private func fallbackWipeView(containerWidth: CGFloat, font: NSFont, fontSize: CGFloat, fontWeight: Font.Weight, isBgVocal: Bool) -> some View {
        let effectiveWidth = containerWidth - (isBgVocal ? 24 : 0)
        let lines = LyricLineLayoutCache.shared.wrappedLines(for: line, width: effectiveWidth, font: font)
        let totalChars = max(1, lines.reduce(0) { $0 + $1.count })
        
        var charAccumulator = 0
        let lineTiming: [(ls: Double, le: Double)] = lines.map { l in
            let ls = Double(charAccumulator) / Double(totalChars)
            charAccumulator += l.count
            let le = Double(charAccumulator) / Double(totalChars)
            return (ls, le)
        }
        
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<lines.count, id: \.self) { i in
                let lineText = lines[i]
                let lineWidth = lineText.size(withAttributes: [.font: font]).width
                let ls = lineTiming[i].ls
                let le = lineTiming[i].le
                
                let rawLp = (fallbackProgress - ls) / max(0.001, (le - ls))
                let lp = max(0, min(1, rawLp))
                
                let fadeWidth: CGFloat = 24
                let currentX = (lineWidth + fadeWidth) * lp - fadeWidth
                let fadeStart = max(0.0, min(1.0, currentX / max(1.0, lineWidth)))
                let fadeEnd = max(0.0, min(1.0, (currentX + fadeWidth) / max(1.0, lineWidth)))
                
                let isLineSinging = lp > 0.0 && lp < 1.0
                let isLineFullySung = lp >= 1.0
                
                let glowOpacity: Double = isLineSinging ? 0.65 : (isLineFullySung ? 0.35 : 0.0)
                let glowRadius: CGFloat = isLineSinging ? 5.0 : (isLineFullySung ? 3.0 : 0.0)
                
                ZStack(alignment: .leading) {
                    Text(lineText)
                        .font(.system(size: fontSize, weight: fontWeight))
                        .italic(isBgVocal)
                        .foregroundColor(.white.opacity(isHovered ? 0.75 : (isActive ? 0.35 : (isPast ? 0.32 : 0.60))))
                        .animation(.easeInOut(duration: 0.38), value: isActive)
                    
                    Text(lineText)
                        .font(.system(size: fontSize, weight: fontWeight))
                        .italic(isBgVocal)
                        .foregroundColor(.white)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: fadeStart),
                                    .init(color: .clear, location: fadeEnd)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .white.opacity(glowOpacity), radius: glowRadius)
                        .opacity(lp > 0.0 ? (isActive ? 1.0 : 0.0) : 0.0)
                        .animation(.easeInOut(duration: 0.38), value: isActive)
                }
                .frame(height: isBgVocal ? 22 : 28, alignment: .leading)
            }
        }
        .frame(width: effectiveWidth, alignment: .leading)
    }
}

// MARK: - Single Word Lyric Item (Apple Music Continuous Glow Decay & Seamless Flow)
struct WordLyricItemView: View {
    let word: LyricWord
    let isActive: Bool
    let isPast: Bool
    let isHovered: Bool
    let currentTime: TimeInterval
    var fontSize: CGFloat = 20
    var fontWeight: Font.Weight = .bold
    var isItalic: Bool = false
    
    var body: some View {
        let font = Font.system(size: fontSize, weight: fontWeight)
        let wordStart = word.startTime
        let wordEnd = word.endTime
        let wordDuration = max(0.06, wordEnd - wordStart)
        
        // Continuous wipe progress: 0.0 before start, 0.0->1.0 while singing, 1.0 when sung
        let rawProgress = (currentTime - wordStart) / wordDuration
        let progress: CGFloat = CGFloat(max(0.0, min(1.0, rawProgress)))
        
        let hasStarted = currentTime >= wordStart
        let isActivelySinging = isActive && (currentTime >= wordStart && currentTime < wordEnd)
        
        let glow = computeGlow(hasStarted: hasStarted, isActivelySinging: isActivelySinging, wordEnd: wordEnd)
        
        ZStack(alignment: .leading) {
            // Base layer: unlit typography with smooth opacity transition
            Text(word.text)
                .font(font)
                .italic(isItalic)
                .foregroundColor(.white.opacity(isHovered ? 0.75 : (isActive ? 0.35 : (isPast ? 0.32 : 0.60))))
                .animation(.easeInOut(duration: 0.38), value: isActive)
            
            // Illuminated layer: SINGLE stable view that never unmounts while active
            Text(word.text)
                .font(font)
                .italic(isItalic)
                .foregroundColor(.white)
                .mask(
                    GeometryReader { geo in
                        let w = geo.size.width
                        let fadeWidth: CGFloat = 16.0
                        let leadX = (w + fadeWidth) * progress - fadeWidth
                        let fadeStart = max(0.0, min(1.0, leadX / max(1.0, w)))
                        let fadeEnd = max(0.0, min(1.0, (leadX + fadeWidth) / max(1.0, w)))
                        
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: fadeStart),
                                .init(color: .clear, location: fadeEnd)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                )
                .shadow(color: .white.opacity(glow.opacity), radius: glow.radius)
                .opacity(isActive ? (hasStarted ? 1.0 : 0.0) : 0.0)
                .animation(.easeInOut(duration: 0.38), value: isActive)
        }
        .scaleEffect(isActivelySinging ? 1.08 : 1.0, anchor: .bottomLeading)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isActivelySinging)
    }
    
    private func computeGlow(hasStarted: Bool, isActivelySinging: Bool, wordEnd: TimeInterval) -> (opacity: Double, radius: CGFloat) {
        if isActivelySinging {
            return (0.85, 6.0)
        } else if hasStarted {
            let timeSinceEnd = max(0.0, currentTime - wordEnd)
            let decayDuration: Double = 0.32
            let decayT = min(1.0, timeSinceEnd / decayDuration)
            // Cosine easing: starts with 0 derivative at peak, decays smoothly down to 0
            let decayFactor = 0.5 * (1.0 + cos(decayT * .pi)) // 1.0 -> 0.0
            let opacity = 0.35 + 0.40 * decayFactor
            let radius = 2.8 + 2.7 * CGFloat(decayFactor)
            return (opacity, radius)
        } else {
            return (0.0, 0.0)
        }
    }
}

// MARK: - Native NSMenu for Settings
// Fixes SwiftUI Menu submenu flickering bug in NSPopover
struct NativeSettingsMenu: NSViewRepresentable {
    @AppStorage("showLyrics") var showLyrics = true
    @AppStorage("showAlbumArt") var showAlbumArt = true
    @AppStorage("audioFeaturesEnabled") var audioFeaturesEnabled = true
    @AppStorage("musicSourceMode") var musicSourceMode = "Auto"
    @AppStorage("hapticIntensity") var hapticIntensity = 0
    @AppStorage("hapticActuatorType") var hapticActuatorType = 0  // 0 = Auto
    @AppStorage("waveformBars") var waveformBars = 14
    @AppStorage("lyricsMaxWidth") var lyricsMaxWidth: Int = 200
    
    func makeNSView(context: Context) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        return button
    }
    
    func updateNSView(_ nsView: NSButton, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    class Coordinator: NSObject {
        var parent: NativeSettingsMenu
        
        init(_ parent: NativeSettingsMenu) {
            self.parent = parent
        }
        
        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu(title: "Settings")
            
            // ── Music Source Submenu ──────────────────────────────────────────
            let sourceItem = NSMenuItem(title: "Music Source", action: nil, keyEquivalent: "")
            let sourceMenu = NSMenu(title: "Music Source")
            let sources = [
                ("Auto", "Auto (Detect Active Player)"),
                ("Spotify", "Spotify"),
                ("Apple Music", "Apple Music")
            ]
            for (key, title) in sources {
                let item = NSMenuItem(title: title, action: #selector(setMusicSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = key
                item.state = parent.musicSourceMode == key ? .on : .off
                sourceMenu.addItem(item)
            }
            sourceItem.submenu = sourceMenu
            menu.addItem(sourceItem)
            menu.addItem(.separator())
            
            let lyricsItem = NSMenuItem(title: "Lyrics in Menu Bar", action: #selector(toggleLyrics), keyEquivalent: "")
            lyricsItem.target = self
            lyricsItem.state = parent.showLyrics ? .on : .off
            menu.addItem(lyricsItem)
            
            let albumItem = NSMenuItem(title: "Album Cover", action: #selector(toggleAlbum), keyEquivalent: "")
            albumItem.target = self
            albumItem.state = parent.showAlbumArt ? .on : .off
            menu.addItem(albumItem)

            let audioItem = NSMenuItem(title: "Audio Visualizer (Tap)", action: #selector(toggleAudioFeatures), keyEquivalent: "")
            audioItem.target = self
            audioItem.state = parent.audioFeaturesEnabled ? .on : .off
            menu.addItem(audioItem)
            
            let widthItem = NSMenuItem(title: "Lyrics Width", action: nil, keyEquivalent: "")
            let widthMenu = NSMenu(title: "Lyrics Width")
            var widths = [0, 50, 100, 150, 200, 250, 300]
            if !widths.contains(parent.lyricsMaxWidth) {
                widths.append(parent.lyricsMaxWidth)
                widths.sort()
            }
            for w in widths {
                let title = w == 0 ? "Off" : "\(w) px"
                let item = NSMenuItem(title: title, action: #selector(setWidth(_:)), keyEquivalent: "")
                item.target = self
                item.tag = w
                item.state = parent.lyricsMaxWidth == w ? .on : .off
                widthMenu.addItem(item)
            }
            widthMenu.addItem(.separator())
            let wCustomItem = NSMenuItem(title: "Custom...", action: #selector(promptCustomWidth), keyEquivalent: "")
            wCustomItem.target = self
            widthMenu.addItem(wCustomItem)
            widthItem.submenu = widthMenu
            menu.addItem(widthItem)
            
            menu.addItem(.separator())
            
            let hapticsItem = NSMenuItem(title: "Haptics", action: nil, keyEquivalent: "")
            let hapticsMenu = NSMenu(title: "Haptics")
            let hModes = ["Off", "Light", "Medium", "Firm"]
            for (i, mode) in hModes.enumerated() {
                let item = NSMenuItem(title: mode, action: #selector(setHaptic(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.state = parent.hapticIntensity == i ? .on : .off
                hapticsMenu.addItem(item)
            }

            // ── Haptic Feel submenu: test MTActuator types ────────────────────
            hapticsMenu.addItem(.separator())
            let feelItem = NSMenuItem(title: "Haptic Feel", action: nil, keyEquivalent: "")
            let feelMenu = NSMenu(title: "Haptic Feel")

            // Type descriptions based on physics / reverse-engineering
            let types: [(tag: Int, label: String, desc: String)] = [
                (0, "Auto",   "Auto (kick=6, beat=4)"),
                (1, "Type 1", "1 — Very light tap"),
                (2, "Type 2", "2 — Light-medium click"),
                (3, "Type 3", "3 — Standard click"),
                (4, "Type 4", "4 — Sharp crisp ★ Pacinian"),
                (5, "Type 5", "5 — Medium-heavy"),
                (6, "Type 6", "6 — Deep sub-bass thump")
            ]
            for t in types {
                let item = NSMenuItem(title: t.desc, action: #selector(setHapticType(_:)), keyEquivalent: "")
                item.target = self
                item.tag = t.tag
                item.state = parent.hapticActuatorType == t.tag ? .on : .off
                feelMenu.addItem(item)
            }
            feelMenu.addItem(.separator())
            // Test button: fires each type sequentially so user can feel them
            let testItem = NSMenuItem(title: "▶ Test All Types (0.4s apart)", action: #selector(testAllHapticTypes), keyEquivalent: "")
            testItem.target = self
            feelMenu.addItem(testItem)

            feelItem.submenu = feelMenu
            hapticsMenu.addItem(feelItem)
            // ─────────────────────────────────────────────────────────────────

            hapticsItem.submenu = hapticsMenu
            menu.addItem(hapticsItem)
            
            let waveItem = NSMenuItem(title: "Waveform", action: nil, keyEquivalent: "")
            let waveMenu = NSMenu(title: "Waveform")
            var wModes = [0, 6, 10, 14, 24, 32, 48, 128]
            if !wModes.contains(parent.waveformBars) {
                wModes.append(parent.waveformBars)
                wModes.sort()
            }
            for bars in wModes {
                let title = bars == 0 ? "Off" : "\(bars) Bars"
                let item = NSMenuItem(title: title, action: #selector(setWaveform(_:)), keyEquivalent: "")
                item.target = self
                item.tag = bars
                item.state = parent.waveformBars == bars ? .on : .off
                waveMenu.addItem(item)
            }
            waveMenu.addItem(.separator())
            let waveCustomItem = NSMenuItem(title: "Custom...", action: #selector(promptCustomWaveform), keyEquivalent: "")
            waveCustomItem.target = self
            waveMenu.addItem(waveCustomItem)
            waveItem.submenu = waveMenu
            menu.addItem(waveItem)
            
            let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
            menu.addItem(loginItem)
            
            menu.addItem(.separator())
            
            let aboutItem = NSMenuItem(title: "About & License...", action: #selector(showAbout), keyEquivalent: "")
            aboutItem.target = self
            menu.addItem(aboutItem)
            
            menu.addItem(.separator())
            
            let quitItem = NSMenuItem(title: "Quit LyricsMenuBar", action: #selector(quit), keyEquivalent: "")
            quitItem.target = self
            menu.addItem(quitItem)
            
            let pt = NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 5)
            menu.popUp(positioning: nil, at: pt, in: sender)
        }
        
        @objc func setMusicSource(_ sender: NSMenuItem) {
            if let key = sender.representedObject as? String {
                parent.musicSourceMode = key
                UserDefaults.standard.set(key, forKey: "musicSourceMode")
                let bundleID = (key == "Apple Music") ? "com.apple.Music" : "com.spotify.client"
                NotificationCenter.default.post(name: Notification.Name("ActiveMusicSourceChanged"), object: nil, userInfo: ["bundleID": bundleID])
            }
        }
        
        @objc func showAbout() {
            let alert = NSAlert()
            alert.messageText = "Lyrics Menu Bar 1.2.0"
            alert.informativeText = "Native Liquid Glass UI for Spotify & Apple Music\n\nLicensed under the MIT License\nCopyright © 2026 Puwadon and Contributors\n\nOpen Source & Free."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        
        @objc func toggleLyrics() { parent.showLyrics.toggle() }
        @objc func toggleAlbum() { parent.showAlbumArt.toggle() }
        @objc func toggleAudioFeatures() {
            parent.audioFeaturesEnabled.toggle()
            UserDefaults.standard.set(parent.audioFeaturesEnabled, forKey: "audioFeaturesEnabled")
            if parent.audioFeaturesEnabled {
                NotificationCenter.default.post(name: Notification.Name("AudioFeaturesEnabled"), object: nil)
            } else {
                NotificationCenter.default.post(name: Notification.Name("AudioFeaturesDisabled"), object: nil)
            }
        }
        @objc func toggleLaunchAtLogin() { LaunchAtLoginManager.isEnabled.toggle() }
        @objc func setWidth(_ sender: NSMenuItem) { parent.lyricsMaxWidth = sender.tag }
        @objc func setHaptic(_ sender: NSMenuItem) { parent.hapticIntensity = sender.tag }
        @objc func setWaveform(_ sender: NSMenuItem) { parent.waveformBars = sender.tag }
        @objc func quit() { NSApplication.shared.terminate(nil) }

        @objc func setHapticType(_ sender: NSMenuItem) {
            parent.hapticActuatorType = sender.tag
            UserDefaults.standard.set(sender.tag, forKey: "hapticActuatorType")
            // Fire a sample of the selected type immediately for confirmation
            let t = sender.tag == 0 ? 4 : Int32(sender.tag)
            HapticManager.shared.testActuatorType(t)
        }

        @objc func testAllHapticTypes() {
            // Fire types 1→6 sequentially, 0.4s apart so user can feel each
            let types: [Int32] = [1, 2, 3, 4, 5, 6]
            for (i, t) in types.enumerated() {
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Double(i) * 0.4) {
                    HapticManager.shared.testActuatorType(t)
                }
            }
        }
        
        @objc func promptCustomWidth() {
            let alert = NSAlert()
            alert.messageText = "Custom Lyrics Width"
            alert.informativeText = "Enter max width in pixels (e.g., 450). Maximum allowed is 1000 px to prevent Menu Bar overflow:"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            input.stringValue = String(parent.lyricsMaxWidth)
            alert.accessoryView = input
            
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let val = Int(input.stringValue) {
                parent.lyricsMaxWidth = min(max(0, val), 1000)
            }
        }
        
        @objc func promptCustomWaveform() {
            let alert = NSAlert()
            alert.messageText = "Custom Waveform Bars"
            alert.informativeText = "Enter number of bars. Maximum allowed is 128 to prevent Menu Bar overflow:"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            input.stringValue = String(parent.waveformBars)
            alert.accessoryView = input
            
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let val = Int(input.stringValue) {
                parent.waveformBars = min(max(0, val), 128)
            }
        }
    }
}

