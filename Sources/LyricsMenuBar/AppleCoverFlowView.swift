import SwiftUI
import AppKit

// MARK: - Cover Flow Item Model
public struct CoverFlowItem: Identifiable, Equatable {
    public let id: String
    public let track: MusicTrack?
    public let isCurrent: Bool
    public let fallbackIcon: String
    public let image: NSImage?
    
    public init(
        id: String,
        track: MusicTrack?,
        isCurrent: Bool = false,
        fallbackIcon: String = "music.note",
        image: NSImage? = nil
    ) {
        self.id = id
        self.track = track
        self.isCurrent = isCurrent
        self.fallbackIcon = fallbackIcon
        self.image = image
    }
}

// MARK: - Apple Cover Flow View (Preset from ashishgogula/coverflow)
public struct AppleCoverFlowView: View {
    public let items: [CoverFlowItem]
    public let activeIndex: Int
    public let scrollPosition: Double
    public let showCoverFlow: Bool
    public let cardSize: CGFloat
    public let cornerRadius: CGFloat
    public var onCardTap: ((Int, CoverFlowItem) -> Void)? = nil
    
    // Apple Preset constants from ashishgogula/coverflow (scaled from 400px to cardSize)
    // 400px baseline: rotation = 67, centerGap = 180, stackSpacing = 60
    private var rotation: Double { 67.0 }
    private var centerGap: CGFloat { cardSize * (180.0 / 400.0) }       // 54pt at 120pt card
    private var stackSpacing: CGFloat { cardSize * (60.0 / 400.0) }    // 18pt at 120pt card
    
    public init(
        items: [CoverFlowItem],
        activeIndex: Int,
        scrollPosition: Double,
        showCoverFlow: Bool,
        cardSize: CGFloat = 120,
        cornerRadius: CGFloat = 14,
        onCardTap: ((Int, CoverFlowItem) -> Void)? = nil
    ) {
        self.items = items
        self.activeIndex = activeIndex
        self.scrollPosition = scrollPosition
        self.showCoverFlow = showCoverFlow
        self.cardSize = cardSize
        self.cornerRadius = cornerRadius
        self.onCardTap = onCardTap
    }
    
    public var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let pos = Double(index) - scrollPosition
                let absPos = abs(pos)
                
                // 1. Apple Preset Rotation (67 degrees)
                let rotateY: Double = {
                    if absPos < 0.5 {
                        return -pos * (rotation * 2.0)
                    } else {
                        return pos < 0 ? rotation : -rotation
                    }
                }()
                
                // 2. Apple Preset Horizontal Offset (centerGap = 54, stackSpacing = 18)
                let xOffset: CGFloat = {
                    if absPos < 1.0 {
                        return CGFloat(pos) * centerGap
                    } else {
                        let extra = CGFloat(absPos - 1.0) * stackSpacing
                        return pos < 0 ? (-centerGap - extra) : (centerGap + extra)
                    }
                }()
                
                // 3. Apple Preset Scale / Depth
                let scale: CGFloat = {
                    if absPos < 0.5 {
                        return 1.0 - CGFloat(absPos) * 0.16
                    } else {
                        return 0.92
                    }
                }()
                
                // 4. Brightness (center is 1.0, sides dim down)
                let brightness: Double = {
                    if absPos < 0.5 {
                        return -absPos * 0.35
                    } else {
                        return -0.20
                    }
                }()
                
                // 5. Opacity (visible within HUD margins, smooth fade if outside)
                let opacity: Double = {
                    if !showCoverFlow {
                        return absPos < 0.5 ? 1.0 : 0.0
                    }
                    if absPos <= 1.15 {
                        return 1.0
                    } else if absPos <= 2.0 {
                        return max(0.0, 1.0 - (absPos - 1.15) * 1.3)
                    } else {
                        return 0.0
                    }
                }()
                
                // 6. Z-Index (center card always on top)
                let zIndex: Double = 1000.0 - absPos * 10.0
                
                CoverFlowCard(
                    item: item,
                    size: cardSize,
                    cornerRadius: cornerRadius
                )
                .rotation3DEffect(
                    .degrees(showCoverFlow ? rotateY : 0.0),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    perspective: 0.0
                )
                .scaleEffect(showCoverFlow ? scale : (absPos < 0.5 ? 1.0 : 0.75))
                .offset(x: showCoverFlow ? xOffset : 0.0)
                .brightness(showCoverFlow ? brightness : 0.0)
                .opacity(opacity)
                .zIndex(zIndex)
                .contentShape(Rectangle())
                .onTapGesture {
                    onCardTap?(index, item)
                }
            }
        }
        .frame(width: cardSize, height: cardSize)
    }
}

// MARK: - Individual Card View
struct CoverFlowCard: View {
    let item: CoverFlowItem
    let size: CGFloat
    let cornerRadius: CGFloat
    
    private var resolvedImage: NSImage? {
        if let direct = item.image { return direct }
        if let t = item.track {
            let key = ArtworkCache.cacheKey(for: t)
            if let cached = ArtworkCache.shared.image(forKey: key) ?? ArtworkCache.shared.image(forKey: t.id) {
                return cached
            }
            if let data = t.artworkData, let img = NSImage(data: data) {
                return img
            }
        }
        return nil
    }
    
    var body: some View {
        Group {
            if let img = resolvedImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: item.fallbackIcon)
                        .font(.system(size: item.isCurrent ? 36 : 24, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
    }
}
