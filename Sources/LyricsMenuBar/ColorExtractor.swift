import Foundation
import AppKit
import CoreImage
import SwiftUI

public struct WaveformTheme: Sendable {
    public var topColor: NSColor
    public var bottomColor: NSColor
    public var glowColor: NSColor
    public var accentColor: NSColor
    
    public static let fallback = WaveformTheme(
        topColor: NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.1, alpha: 1.0),
        bottomColor: NSColor(calibratedRed: 1.0, green: 0.50, blue: 0.0, alpha: 1.0),
        glowColor: NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.1, alpha: 0.65),
        accentColor: NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.3, alpha: 1.0)
    )
}

public struct ColorExtractor {
    public static func extractGradientColors(from urlString: String) async -> [Color] {
        guard let url = URL(string: urlString) else {
            return [.cyan, .blue, .purple, .pink]
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = NSImage(data: data) {
                return extract(from: image)
            }
        } catch {
            print("Error downloading image: \(error)")
        }
        
        return [.cyan, .blue, .purple, .pink]
    }
    
    public static func extract(from image: NSImage) -> [Color] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [.cyan, .purple]
        }
        let ciImage = CIImage(cgImage: cgImage)
        
        let extent = ciImage.extent
        let leftRect = CGRect(x: 0, y: 0, width: extent.width / 3, height: extent.height)
        let midRect = CGRect(x: extent.width / 3, y: 0, width: extent.width / 3, height: extent.height)
        let rightRect = CGRect(x: extent.width * 2/3, y: 0, width: extent.width / 3, height: extent.height)
        
        let color1 = averageColor(of: ciImage, in: leftRect) ?? .cyan
        let color2 = averageColor(of: ciImage, in: midRect) ?? .blue
        let color3 = averageColor(of: ciImage, in: rightRect) ?? .purple
        
        return [color1, color2, color3].map { $0.boostSaturate() }
    }
    
    private static func averageColor(of image: CIImage, in rect: CGRect) -> Color? {
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        
        guard let outputImage = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        
        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        return Color(red: r, green: g, blue: b)
    }
    
    public static func extractWaveformTheme(from image: NSImage) -> WaveformTheme {
        let targetW = 48
        let targetH = 48
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: targetW * 4,
            bitsPerPixel: 32
        ) else {
            return .fallback
        }
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
                   from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        
        var bucketScores = [Double](repeating: 0.0, count: 12)
        var bucketR = [Double](repeating: 0.0, count: 12)
        var bucketG = [Double](repeating: 0.0, count: 12)
        var bucketB = [Double](repeating: 0.0, count: 12)
        
        for y in 0..<targetH {
            for x in 0..<targetW {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                
                // Discard near-black, washed-out muddy grays, and near-white
                if b < 0.12 || (s < 0.15 && b > 0.88) || s < 0.14 {
                    continue
                }
                
                let bucket = Int(h * 12.0) % 12
                let weight = Double(s * (1.0 - abs(b - 0.52) * 0.4))
                bucketScores[bucket] += weight
                
                var r: CGFloat = 0, g: CGFloat = 0, blue: CGFloat = 0
                color.getRed(&r, green: &g, blue: &blue, alpha: &a)
                bucketR[bucket] += Double(r) * weight
                bucketG[bucket] += Double(g) * weight
                bucketB[bucket] += Double(blue) * weight
            }
        }
        
        let sortedBuckets = (0..<12).sorted { bucketScores[$0] > bucketScores[$1] }
        let primaryBucket = sortedBuckets.first { bucketScores[$0] > 0.3 }
        
        guard let pIdx = primaryBucket, bucketScores[pIdx] > 0 else {
            // Elegant monochrome theme for black & white / grayscale covers
            return WaveformTheme(
                topColor: NSColor.white,
                bottomColor: NSColor(deviceWhite: 0.70, alpha: 1.0),
                glowColor: NSColor.white.withAlphaComponent(0.65),
                accentColor: NSColor(deviceWhite: 0.95, alpha: 1.0)
            )
        }
        
        let avgR = bucketR[pIdx] / bucketScores[pIdx]
        let avgG = bucketG[pIdx] / bucketScores[pIdx]
        let avgB = bucketB[pIdx] / bucketScores[pIdx]
        let avgColor = NSColor(calibratedRed: avgR, green: avgG, blue: avgB, alpha: 1.0)
        
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        avgColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        
        // True-tone Apple Music vibrancy: crisp, saturated, rich tone (never muddy or washed out)
        let vibrantSat = max(0.55, min(0.95, s * 1.25))
        let topB = max(0.68, min(0.94, b * 1.7 + 0.22))
        let bottomB = max(0.42, min(0.72, b * 1.35 + 0.08))
        
        let topColor = NSColor(calibratedHue: h, saturation: vibrantSat * 0.88, brightness: topB, alpha: 1.0)
        let bottomColor = NSColor(calibratedHue: h, saturation: vibrantSat, brightness: bottomB, alpha: 1.0)
        let accentColor = NSColor(calibratedHue: h, saturation: max(0.45, vibrantSat * 0.70), brightness: min(1.0, topB + 0.12), alpha: 1.0)
        let glowColor = topColor.withAlphaComponent(0.40)
        
        return WaveformTheme(topColor: topColor, bottomColor: bottomColor, glowColor: glowColor, accentColor: accentColor)
    }
}

extension NSColor {
    func vibrantVersion(brightnessBoost: CGFloat, saturationBoost: CGFloat) -> NSColor {
        guard let rgb = self.usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        
        let newS = min(1.0, max(0.55, s * 1.35 + saturationBoost))
        let newB = min(1.0, max(0.70, b + brightnessBoost))
        return NSColor(calibratedHue: h, saturation: newS, brightness: newB, alpha: 1.0)
    }
}

extension Color {
    func boostSaturate() -> Color {
        let nsColor = NSColor(self)
        return Color(nsColor.vibrantVersion(brightnessBoost: 0.2, saturationBoost: 0.3))
    }
}
