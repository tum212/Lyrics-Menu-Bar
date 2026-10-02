import SwiftUI
import AppKit
import Combine

// MARK: - Cover Flow Item Model
struct CoverFlowItem: Identifiable {
    let id: String
    let track: MusicTrack
    let index: Int
}

// MARK: - iPod Classic 7G 3D Cover Flow View
struct CoverFlowView: View {
    @ObservedObject var musicService: MusicService
    @Binding var isCoverFlowMode: Bool
    
    @State private var dragOffset: CGFloat = 0.0
    @State private var isDragging: Bool = false
    
    private var items: [CoverFlowItem] {
        var list: [CoverFlowItem] = []
        var idx = 0
        for track in musicService.sessionHistory {
            list.append(CoverFlowItem(id: "hist_\(track.id)_\(idx)", track: track, index: idx))
            idx += 1
        }
        if let current = musicService.currentTrack {
            list.append(CoverFlowItem(id: "current_\(current.id)_\(idx)", track: current, index: idx))
            idx += 1
        }
        for track in musicService.upcomingQueue {
            list.append(CoverFlowItem(id: "queue_\(track.id)_\(idx)", track: track, index: idx))
            idx += 1
        }
        return list
    }
    
    private var centerIndex: Int {
        return musicService.sessionHistory.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: Top Navigation Pill (Lyrics <-> Cover Flow)
            topToggleBar
                .padding(.top, 10)
            
            Spacer(minLength: 2)
            
            // MARK: 3D Parallel Projection Carousel
            carouselContainer
                .frame(height: 124)
            
            Spacer(minLength: 4)
            
            // MARK: Current Track Info
            trackInfoBar
            
            Spacer(minLength: 4)
            
            // MARK: Timeline Scrubber
            scrubberBar
            
            Spacer(minLength: 4)
            
            // MARK: Playback Controls
            playbackControls
                .padding(.bottom, 8)
        }
        .frame(width: 480, height: 240)
    }
    
    // MARK: - Top Toggle Bar
    private var topToggleBar: some View {
        HStack {
            HStack(spacing: 2) {
                Button(action: {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                        isCoverFlowMode = false
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Lyrics")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())
                    .foregroundColor(.white.opacity(0.70))
                }
                .buttonStyle(PlainButtonStyle())
                
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Cover Flow")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.24))
                .clipShape(Capsule())
                .foregroundColor(.white)
            }
            .padding(2)
            .background(Color.black.opacity(0.25))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
    }
    
    // MARK: - 3D Carousel Container
    private var carouselContainer: some View {
        GeometryReader { _ in
            ZStack {
                let allItems = self.items
                let baseCenter = CGFloat(self.centerIndex)
                let scrubOffset = -self.dragOffset / 52.0
                
                if allItems.isEmpty {
                    emptyPlaceholder
                } else {
                    ForEach(allItems) { item in
                        let delta = CGFloat(item.index) - baseCenter + scrubOffset
                        renderParallelSlide(item: item, delta: delta)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { val in
                        isDragging = true
                        dragOffset = val.translation.width
                    }
                    .onEnded { val in
                        isDragging = false
                        let velocity = val.predictedEndTranslation.width - val.translation.width
                        let totalDelta = val.translation.width + velocity * 0.20
                        
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.76)) {
                            dragOffset = 0.0
                        }
                        
                        if totalDelta < -40 {
                            musicService.nextTrack()
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        } else if totalDelta > 40 {
                            musicService.previousTrack()
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        }
                    }
            )
        }
    }
    
    // MARK: - Parallel Projection Math (Apple iPod Classic 7G)
    private struct SlideGeometry {
        let angle: Double
        let xOffset: CGFloat
        let zIndex: Double
        let scale: CGFloat
        let opacity: Double
    }
    
    private func computeSlideGeometry(delta: CGFloat) -> SlideGeometry {
        let absDelta = abs(delta)
        if absDelta < 0.001 {
            return SlideGeometry(angle: 0.0, xOffset: 0.0, zIndex: 100.0, scale: 1.0, opacity: 1.0)
        } else if delta < 0 {
            if delta > -1.0 {
                let t = -delta
                return SlideGeometry(
                    angle: Double(t * 60.0),
                    xOffset: -t * 76.0,
                    zIndex: 99.0,
                    scale: 1.0 - t * 0.12,
                    opacity: 1.0 - Double(t) * 0.10
                )
            } else {
                let stack = -delta - 1.0
                return SlideGeometry(
                    angle: 60.0,
                    xOffset: -76.0 - stack * 34.0,
                    zIndex: max(1.0, 90.0 - Double(stack) * 2.0),
                    scale: 0.88,
                    opacity: max(0.20, 0.90 - Double(stack) * 0.15)
                )
            }
        } else {
            if delta < 1.0 {
                let t = delta
                return SlideGeometry(
                    angle: -Double(t * 60.0),
                    xOffset: t * 76.0,
                    zIndex: 99.0,
                    scale: 1.0 - t * 0.12,
                    opacity: 1.0 - Double(t) * 0.10
                )
            } else {
                let stack = delta - 1.0
                return SlideGeometry(
                    angle: -60.0,
                    xOffset: 76.0 + stack * 34.0,
                    zIndex: max(1.0, 90.0 - Double(stack) * 2.0),
                    scale: 0.88,
                    opacity: max(0.20, 0.90 - Double(stack) * 0.15)
                )
            }
        }
    }
    
    @ViewBuilder
    private func renderParallelSlide(item: CoverFlowItem, delta: CGFloat) -> some View {
        let geom = computeSlideGeometry(delta: delta)
        let isCenter = abs(delta) < 0.3
        
        CoverFlowCard(
            track: item.track,
            isCurrent: item.index == centerIndex,
            musicService: musicService
        )
        .rotation3DEffect(
            .degrees(geom.angle),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            perspective: 0.5
        )
        .scaleEffect(geom.scale)
        .offset(x: geom.xOffset)
        .opacity(geom.opacity)
        .zIndex(geom.zIndex)
        .contentShape(Rectangle())
        .onTapGesture {
            handleCardTap(item: item, isCenter: isCenter)
        }
    }
    
    private func handleCardTap(item: CoverFlowItem, isCenter: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if isCenter {
            // Clicking center artwork smoothly toggles back to lyrics
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                isCoverFlowMode = false
            }
        } else if item.index == centerIndex - 1 {
            musicService.previousTrack()
        } else if item.index == centerIndex + 1 {
            musicService.nextTrack()
        } else {
            musicService.playTrack(item.track)
        }
    }
    
    // MARK: - Track Info
    private var trackInfoBar: some View {
        VStack(spacing: 2) {
            Text(musicService.currentTrack?.name ?? "No Music Playing")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.45), radius: 2, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.tail)
            
            Text("\(musicService.currentTrack?.artist ?? "") — \(musicService.currentTrack?.album ?? "")")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
                .shadow(color: Color.black.opacity(0.40), radius: 2, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 380)
    }
    
    // MARK: - Timeline Scrubber
    private var scrubberBar: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let current = musicService.currentTime
            let dur = max(1.0, musicService.currentTrack?.duration ?? 1.0)
            let progress = min(1.0, max(0.0, current / dur))
            
            HStack(spacing: 8) {
                Text(formatTime(current))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.60))
                    .frame(width: 32, alignment: .trailing)
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 3)
                        
                        Capsule()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(progress), height: 3)
                    }
                    .frame(height: 12)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                let pct = min(1.0, max(0.0, val.location.x / geo.size.width))
                                musicService.seek(to: Double(pct) * dur)
                            }
                    )
                }
                .frame(height: 12)
                
                Text(formatTime(dur))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.60))
                    .frame(width: 32, alignment: .leading)
            }
            .frame(width: 360)
        }
    }
    
    // MARK: - Playback Controls
    private var playbackControls: some View {
        HStack(spacing: 24) {
            AppleMusicControlButton(systemName: "backward.fill", size: 14, frameSize: 30) {
                musicService.previousTrack()
            }
            AppleMusicControlButton(systemName: musicService.isPlaying ? "pause.fill" : "play.fill", size: 17, frameSize: 34) {
                musicService.playPause()
            }
            AppleMusicControlButton(systemName: "forward.fill", size: 14, frameSize: 30) {
                musicService.nextTrack()
            }
        }
    }
    
    private var emptyPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text("No Tracks in Queue")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let mins = s / 60
        let secs = s % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Cover Flow Card with Apple Gradient Mirror Reflection
struct CoverFlowCard: View {
    let track: MusicTrack
    let isCurrent: Bool
    @ObservedObject var musicService: MusicService
    @State private var fetchedImage: NSImage?
    
    var body: some View {
        VStack(spacing: 2) {
            // Front Card
            artworkContent
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.75)
                )
                .shadow(color: Color.black.opacity(isCurrent ? 0.45 : 0.25), radius: isCurrent ? 8 : 4, x: 0, y: 3)
            
            // Mirror Reflection below
            artworkContent
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scaleEffect(y: -1)
                .frame(width: 88, height: 26, alignment: .top)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.35), location: 0),
                            .init(color: .white.opacity(0.0), location: 0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(0.85)
        }
        .frame(width: 88, height: 116)
        .task(id: track.id) {
            let key = ArtworkCache.cacheKey(for: track)
            if let cached = ArtworkCache.shared.image(forKey: key) {
                fetchedImage = cached
                return
            }
            if let url = ArtworkLoader.sanitizeArtworkURL(track.artworkURL) {
                if let loaded = await ArtworkLoader.fetchImage(from: url, cacheKey: key) {
                    fetchedImage = loaded
                }
            }
        }
    }
    
    @ViewBuilder
    private var artworkContent: some View {
        if isCurrent, let active = musicService.activeArtworkImage {
            Image(nsImage: active)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let img = fetchedImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let data = track.artworkData, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.20), Color(white: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }
}
