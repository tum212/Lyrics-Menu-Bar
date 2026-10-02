import SwiftUI
import AppKit

// MARK: - 3D Cover Flow Album Peek Card
struct AlbumPeekCard: View {
    let track: MusicTrack?
    let fallbackIcon: String
    var size: CGFloat = 120
    var cornerRadius: CGFloat = 14
    @State private var loadedImage: NSImage?

    var body: some View {
        Group {
            if let data = track?.artworkData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let img = loadedImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: fallbackIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .task(id: track?.id) {
            guard let t = track else { return }
            if t.artworkData != nil { return }
            let key = ArtworkCache.cacheKey(for: t)
            if let cached = ArtworkCache.shared.image(forKey: key) {
                loadedImage = cached
                return
            }
            if let url = ArtworkLoader.sanitizeArtworkURL(t.artworkURL) {
                if let fetched = await ArtworkLoader.fetchImage(from: url, cacheKey: key) {
                    loadedImage = fetched
                }
            }
        }
    }
}
