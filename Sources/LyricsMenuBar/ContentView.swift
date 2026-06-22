import SwiftUI
import AppKit

// MARK: - Native macOS Blur
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}

// MARK: - Main View
struct ContentView: View {
    @ObservedObject var spotify: SpotifyService
    @ObservedObject var lyricsService: LyricsService
    @ObservedObject var audioAnalyzer: AudioAnalyzer

    // Track which lyric index is active for scroll animation
    @State private var displayedIndex: Int = 0
    
    // User preferences
    @AppStorage("showLyrics") private var showLyrics = true
    @AppStorage("waveformBars") private var waveformBars = 14
    @AppStorage("showAlbumArt") private var showAlbumArt = true
    @AppStorage("hapticEnabled") private var hapticEnabled = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 24) {
                // MARK: Left Panel - Player (120px wide, scaled down)
                VStack(spacing: 0) {
                    // Album Art
                    Group {
                        if let track = spotify.currentTrack,
                           let urlString = track.artworkURL,
                           let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    placeholderArt
                                }
                            }
                        } else {
                            placeholderArt
                        }
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 5)

                    Spacer().frame(height: 10)

                    // Track Info (Centered)
                    VStack(spacing: 2) {
                        Text(spotify.currentTrack?.name ?? "No Music Playing")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.center)

                        Text(spotify.currentTrack?.artist ?? "Open Spotify to start")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 120, alignment: .center)

                    Spacer().frame(height: 10)

                    // Playback Controls — perfectly centered
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Button(action: { spotify.previousTrack() }) {
                            Image(systemName: "backward.fill").font(.system(size: 14))
                        }
                        .buttonStyle(PlainButtonStyle()).focusable(false)

                        Spacer(minLength: 0)

                        Button(action: { spotify.playPause() }) {
                            Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20))
                        }
                        .buttonStyle(PlainButtonStyle()).focusable(false)

                        Spacer(minLength: 0)

                        Button(action: { spotify.nextTrack() }) {
                            Image(systemName: "forward.fill").font(.system(size: 14))
                        }
                        .buttonStyle(PlainButtonStyle()).focusable(false)

                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.white)
                    .frame(width: 120)
                }
                .frame(width: 120)

                // MARK: Right Panel - Lyrics with scroll animation
                TimelineView(.animation) { timeline in
                    lyricsPanel(currentDate: timeline.date)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(width: 480, height: 240)

            // Top Right Controls
            HStack(spacing: 8) {
                Menu {
                    Toggle("Lyrics in Menu Bar", isOn: $showLyrics)
                    Toggle(isOn: $showAlbumArt) {
                        Text("Album Cover")
                    }
                    
                    Divider()
                        
                        Toggle(isOn: $hapticEnabled) {
                            Text("Trackpad Haptics")
                        }
                        Picker("Waveform", selection: $waveformBars) {
                            Text("Waveform: Off").tag(0)
                            Text("Waveform: 6 Bars").tag(6)
                            Text("Waveform: 10 Bars").tag(10)
                            Text("Waveform: 14 Bars").tag(14)
                            Text("Waveform: 24 Bars").tag(24)
                            Text("Waveform: 32 Bars").tag(32)
                            Text("Waveform: 48 Bars").tag(48)
                            Text("Waveform: 128 Bars").tag(128)
                        }
                        .pickerStyle(.inline)
                        
                        Divider()
                        
                        Button("Quit LyricsMenuBar") {
                            NSApplication.shared.terminate(nil)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .menuStyle(BorderlessButtonMenuStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button(action: { NotificationCenter.default.post(name: Notification.Name("ClosePopover"), object: nil) }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .focusable(false)
                }
                .padding([.top, .trailing], 16)
        }
        // Dynamic Blurred Album Art Background
        .background(
            ZStack {
                VisualEffectView().ignoresSafeArea()
                if let track = spotify.currentTrack,
                   let urlString = track.artworkURL,
                   let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 60)
                                .opacity(0.8)
                        }
                    }
                    .frame(width: 480, height: 240)
                    .clipped()
                    .ignoresSafeArea()

                    LinearGradient(
                        colors: [Color.black.opacity(0.15), Color.black.opacity(0.65)],
                        startPoint: .top, endPoint: .bottom
                    ).ignoresSafeArea()
                } else {
                    Color.black.opacity(0.5).ignoresSafeArea()
                }
            }
        )
        .onChange(of: spotify.currentTrack?.id) { [spotify] _ in
            if let track = spotify.currentTrack {
                lyricsService.fetchLyrics(trackName: track.name, artistName: track.artist, albumName: track.album)
            } else {
                lyricsService.lyrics = []
            }
            displayedIndex = 0
        }
        .onChange(of: spotify.isPlaying) { [spotify] _ in
            if spotify.isPlaying { audioAnalyzer.start() } else { audioAnalyzer.stop() }
        }
        .onAppear {
            if spotify.isPlaying { audioAnalyzer.start() }
        }
    }

    // MARK: - Lyrics Panel with Apple Music style scroll
    @ViewBuilder
    private func lyricsPanel(currentDate: Date) -> some View {
        let info = getActiveLyricsInfo(currentDate: currentDate)
        let allLyrics = lyricsService.lyrics

        if allLyrics.isEmpty {
            Text(lyricsService.isLoading ? "Loading lyrics..." : (spotify.isPlaying ? "♪" : ""))
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            // Find current index in full lyrics array
            let activeIdx = allLyrics.firstIndex(where: { $0.id == info.activeId }) ?? 0

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(allLyrics.enumerated()), id: \.element.id) { idx, line in
                            let isActive = line.id == info.activeId
                            let isPast = idx < activeIdx

                            Group {
                                if isActive {
                                    // Active line with growing light effect
                                    ActiveLyricView(text: line.text, progress: info.progress)
                                } else {
                                    Text(line.text)
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(isPast ? .white.opacity(0.2) : .white.opacity(0.35))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .id(line.id)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 40) // Give shadow room to bleed
                }
                .padding(.horizontal, -40) // Compensate bounds so ScrollView itself isn't visibly shrunk
                // Apple Music style: scroll current line to ~30% from top
                .onChange(of: info.activeId) { [proxy] newId in
                    if let id = newId {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.3))
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
                gradient: Gradient(colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.8)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func getActiveLyricsInfo(currentDate: Date) -> (lines: [LyricLine], progress: Double, activeId: UUID?) {
        let rawTime = spotify.isPlaying
            ? spotify.playbackPosition + currentDate.timeIntervalSince(spotify.lastUpdateDate)
            : spotify.playbackPosition
            
        let time = max(0, rawTime - 0.4)

        let allLyrics = lyricsService.lyrics
        if allLyrics.isEmpty { return ([], 0.0, nil) }

        let isUnsynced = allLyrics.count > 1 && allLyrics.last!.time == 0
        var currentIndex = 0
        var progress = 0.0

        if isUnsynced {
            let duration = spotify.currentTrack?.duration ?? 100.0
            progress = max(0, min(1, time / duration))
            currentIndex = Int(progress * Double(allLyrics.count))
            if currentIndex >= allLyrics.count { currentIndex = allLyrics.count - 1 }
            progress = 1.0
        } else {
            for (index, line) in allLyrics.enumerated() {
                if line.time <= time { currentIndex = index } else { break }
            }
            if currentIndex < allLyrics.count - 1 {
                let currentStart = allLyrics[currentIndex].time
                let nextStart = allLyrics[currentIndex + 1].time
                let lineDuration = max(0.1, nextStart - currentStart)
                progress = max(0, min(1, (time - currentStart) / lineDuration))
            } else {
                progress = 1.0
            }
        }

        return (allLyrics, progress, allLyrics[currentIndex].id)
    }
}

// MARK: - Active Lyric View (Line-wrapping layout with Orb)
struct ActiveLyricView: View {
    let text: String
    let progress: Double
    
    var body: some View {
        let font = NSFont.systemFont(ofSize: 22, weight: .bold)
        let containerWidth: CGFloat = 288.0
        let lines = getWrappedLines(text: text, width: containerWidth, font: font)
        
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<lines.count, id: \.self) { i in
                let lineText = lines[i]
                let lineWidth = lineText.size(withAttributes: [.font: font]).width
                let ls = Double(i) / Double(lines.count)
                let le = Double(i + 1) / Double(lines.count)
                
                // Calculate local progress for this line
                let rawLp = (progress - ls) / (le - ls)
                let lp = max(0, min(1, rawLp))
                
                ZStack(alignment: .leading) {
                    // 1. Base Text (Dim)
                    Text(lineText)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                    
                    // 2. Highlighted Text (Bright White with soft fade edge)
                    Text(lineText)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .mask(
                            HStack(spacing: 0) {
                                Rectangle().frame(width: max(0, lineWidth * lp - 10))
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 30)
                                Spacer(minLength: 0)
                            }
                        )
                        // A very subtle bloom to make the text pop, like Apple Music
                        .shadow(color: .white.opacity(0.4), radius: 4)
                }
                .frame(height: 28)
            }
        }
        .frame(width: containerWidth, alignment: .leading)
    }
    
    private func getWrappedLines(text: String, width: CGFloat, font: NSFont) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        var lines: [String] = []
        var currentLine = ""
        let safeWidth = max(width, 100)
        
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

