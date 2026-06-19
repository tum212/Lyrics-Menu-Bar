import Foundation
import AppKit
import CoreImage
import SwiftUI

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
    
    private static func extract(from image: NSImage) -> [Color] {
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
        
        let r = CGFloat(bitmap[0]) / 255.0
        let g = CGFloat(bitmap[1]) / 255.0
        let b = CGFloat(bitmap[2]) / 255.0
        
        return Color(red: r, green: g, blue: b)
    }
}

extension Color {
    func boostSaturate() -> Color {
        let nsColor = NSColor(self)
        if let rgbColor = nsColor.usingColorSpace(.deviceRGB) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgbColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // Make colors extremely vibrant for the neon visualizer
            let newS = min(1.0, s * 1.5 + 0.4)
            let newB = min(1.0, b * 1.2 + 0.3)
            return Color(NSColor(calibratedHue: h, saturation: newS, brightness: newB, alpha: a))
        }
        return self
    }
}
