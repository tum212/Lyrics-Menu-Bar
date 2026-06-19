import SwiftUI
import AppKit
import Combine

@main
struct SpoticatApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var popover: NSPopover!
    
    // Core Services
    var spotify = SpotifyService()
    var lyricsService = LyricsService()
    var audioAnalyzer = AudioAnalyzer()
    
    // Menu Bar State
    var lyricsStatusItem: NSStatusItem!
    var artStatusItem: NSStatusItem!
    var updateTimer: Timer?
    private var cachedAlbumArtURL: String?
    private var cachedAlbumArtImage: NSImage?
    private var cachedBlurredAlbumArtImage: NSImage?
    
    private var lastShowWaveform = true
    private var lastShowAlbumArt = true
    private var lastShowLyrics = true
    var cancellables = Set<AnyCancellable>()
    // Lyrics Animation State
    var lastLyricsId: UUID?
    var animatedWidth: CGFloat = 20.0
    // Optimization: skip redraw when content hasn't changed
    var lastRenderedLyricsText: String = ""
    var lastRenderedProgress: Double = -1
    var forceRedrawLyrics: Bool = false
    var animatedOrbAlpha: CGFloat = 0.0
    
    // Waveform Motion Blur State
    var lastAmplitudes: [Double] = []
    
    // Sparkle Animation State
    var trackChangedTime: Date = Date.distantPast
    var lastTrackIdForSparkle: String = ""
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        UserDefaults.standard.register(defaults: [
            "waveformBars": 14,
            "showAlbumArt": true,
            "showLyrics": true
        ])
        
        let contentView = ContentView(
            spotify: spotify,
            lyricsService: lyricsService,
            audioAnalyzer: audioAnalyzer
        )
        
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 480, height: 240)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
        self.popover = popover
        
        self.artStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = self.artStatusItem.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Spoticat")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        self.lyricsStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = self.lyricsStatusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        // Auto-fetch lyrics when track changes, because ContentView might not be visible yet
        spotify.$currentTrack
            .sink { [weak self] track in
                guard let self = self else { return }
                if let track = track {
                    self.lyricsService.fetchLyrics(trackName: track.name, artistName: track.artist, albumName: track.album)
                } else {
                    self.lyricsService.lyrics = []
                }
            }
            .store(in: &cancellables)
        
        // Start live updating the Menu Bar at 20fps for smooth visualizer
        startMenuBarUpdater()
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = artStatusItem.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
    
    func startMenuBarUpdater() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.updateMenuBar()
        }
        if let timer = updateTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    func roundCorners(of image: NSImage, size: NSSize, radius: CGFloat) -> NSImage {
        let roundedImage = NSImage(size: size)
        roundedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius)
        path.addClip()
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        roundedImage.unlockFocus()
        return roundedImage
    }
    
    func updateMenuBar() {
        let waveformBars = UserDefaults.standard.integer(forKey: "waveformBars")
        let showAlbumArt = UserDefaults.standard.bool(forKey: "showAlbumArt")
        let showLyrics = UserDefaults.standard.bool(forKey: "showLyrics")
        
        // Pass dynamic band count to audio analyzer
        if waveformBars > 0 {
            audioAnalyzer.updateBandCount(waveformBars)
        }
        
        // Check for state changes to force redraw
        let prefsChanged = (waveformBars != UserDefaults.standard.integer(forKey: "lastWaveformBars") || showAlbumArt != lastShowAlbumArt || showLyrics != lastShowLyrics)
        UserDefaults.standard.set(waveformBars, forKey: "lastWaveformBars")
        lastShowAlbumArt = showAlbumArt
        lastShowLyrics = showLyrics
        
        lyricsStatusItem?.isVisible = showLyrics
        artStatusItem?.isVisible = (waveformBars > 0) || showAlbumArt
        
        if let track = spotify.currentTrack {
            guard let artButton = self.artStatusItem.button, let lyricsButton = self.lyricsStatusItem.button else { return }
            
            // Fast path: paused + no sparkle + no animation in progress → skip heavy redraw
            let sparkleTime = Date().timeIntervalSince(trackChangedTime)
            let isSparkling = lyricsService.isLoading || sparkleTime < 5.5
            if !spotify.isPlaying && !isSparkling && forceRedrawLyrics == false && !prefsChanged {
                // Still need to show static text but skip 60fps NSImage recreation
                // Only update if lyrics line changed
                let staticText: String
                let allLyrics = lyricsService.lyrics
                if allLyrics.isEmpty {
                    staticText = "\(track.name) - \(track.artist) • \(track.album)"
                } else {
                    let rawTime = spotify.playbackPosition
                    let time = max(0, rawTime - 0.4)
                    var idx = 0
                    for (i, line) in allLyrics.enumerated() { if line.time <= time { idx = i } else { break } }
                    staticText = allLyrics[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "♪" : allLyrics[idx].text
                }
                if staticText == lastRenderedLyricsText { return }  // ← skip if identical
                forceRedrawLyrics = true  // force one redraw for the new static text
            } else {
                forceRedrawLyrics = false
            }
            
            if lastTrackIdForSparkle != track.id {
                lastTrackIdForSparkle = track.id
                trackChangedTime = Date()
            }
            
            // --- 1. LYRICS UPDATING (Left Item) ---
            let rawTime = spotify.isPlaying ? spotify.playbackPosition + Date().timeIntervalSince(spotify.lastUpdateDate) : spotify.playbackPosition
            let time = max(0, rawTime - 0.4)
            let allLyrics = lyricsService.lyrics
            var currentLineText = ""
            var isUnsynced = false
            var currentIndex = 0
            
            var peekedAhead = false
            
            if !allLyrics.isEmpty {
                isUnsynced = allLyrics.count > 1 && allLyrics.last!.time == 0
                if isUnsynced {
                    let duration = track.duration > 0 ? track.duration : 100.0
                    let progress = max(0, min(1, time / duration))
                    currentIndex = Int(progress * Double(allLyrics.count))
                    if currentIndex >= allLyrics.count { currentIndex = allLyrics.count - 1 }
                } else {
                    for (index, line) in allLyrics.enumerated() {
                        if line.time <= time { currentIndex = index } else { break }
                    }
                }
                currentLineText = allLyrics[currentIndex].text
                if currentLineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if currentIndex + 1 < allLyrics.count {
                        let nextText = allLyrics[currentIndex + 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !nextText.isEmpty { 
                            currentLineText = nextText 
                            peekedAhead = true
                        } else { 
                            currentLineText = "♪" 
                        }
                    } else { currentLineText = "♪" }
                }
            } else {
                if lyricsService.isLoading {
                    currentLineText = track.name
                } else {
                    let totalSparkleDuration = 5.5
                    let sparkleTime = Date().timeIntervalSince(trackChangedTime)
                    if sparkleTime < totalSparkleDuration {
                        currentLineText = track.name
                    } else {
                        currentLineText = "\(track.name) - \(track.artist) • \(track.album)"
                    }
                }
            }
            
            if currentLineText.isEmpty { currentLineText = "♪" }
            if currentLineText.count > 75 { currentLineText = String(currentLineText.prefix(72)) + "..." }
            
            lastLyricsId = allLyrics.isEmpty ? nil : allLyrics[currentIndex].id
            
            let font = NSFont.systemFont(ofSize: 14, weight: .regular)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            paragraphStyle.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle]
            let textSize = currentLineText.size(withAttributes: attributes)
            
            var progress = 0.0
            if !allLyrics.isEmpty && currentIndex < allLyrics.count {
                if peekedAhead {
                    progress = 0.0
                } else if isUnsynced {
                    let duration = track.duration > 0 ? track.duration : 100.0
                    progress = max(0, min(1, time / duration))
                } else {
                    if currentIndex < allLyrics.count - 1 {
                        let currentStart = allLyrics[currentIndex].time
                        let nextStart = allLyrics[currentIndex + 1].time
                        let rawDuration = max(0.1, nextStart - currentStart)
                        
                        // Cap duration to a realistic singing speed (~0.15s per char)
                        let estimatedSingingTime = Double(currentLineText.count) * 0.15
                        let activeDuration = min(rawDuration, max(1.5, estimatedSingingTime))
                        
                        progress = max(0, min(1, (time - currentStart) / activeDuration))
                    } else {
                        progress = 1.0
                    }
                }
            }
            
            let glowPad: CGFloat = 6  // padding on each side so glow is not clipped
            let targetWidth = currentLineText == "♪" ? max(textSize.width + glowPad * 2, 10) : max(textSize.width + glowPad * 2, 10)
            animatedWidth += (targetWidth - animatedWidth) * 0.2
            
            if animatedWidth > 2 {
                let lyricsImage = NSImage(size: NSSize(width: animatedWidth, height: 20))
                lyricsImage.isTemplate = false
                lyricsImage.lockFocus()
                
                // Text sits glowPad pixels in from the left edge so glow can spill freely
                let textRect = NSRect(x: glowPad, y: (20 - textSize.height) / 2, width: textSize.width, height: textSize.height)
                
                var grayAttributes = attributes
                grayAttributes[.foregroundColor] = NSColor.white.withAlphaComponent(0.4)
                currentLineText.draw(in: textRect, withAttributes: grayAttributes)
                
                // Target alpha based on progress
                let targetOrbAlpha: CGFloat = (progress > 0.0 && progress < 1.0) ? 1.0 : 0.0
                animatedOrbAlpha += (targetOrbAlpha - animatedOrbAlpha) * 0.15
                
                if progress > 0 || animatedOrbAlpha > 0.01 {
                    let clampedProgress = min(1.0, progress)
                    let currentX = glowPad + textSize.width * CGFloat(clampedProgress)
                    
                    // To avoid text ghosting from CGContext transparency layers, we draw the white text into a separate NSImage
                    let whiteImage = NSImage(size: NSSize(width: animatedWidth, height: 20))
                    whiteImage.lockFocus()
                    
                    // Draw white text with bloom (shadow)
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.white.withAlphaComponent(0.6)
                    shadow.shadowOffset = .zero
                    shadow.shadowBlurRadius = 3
                    shadow.set()
                    
                    var whiteAttributes = attributes
                    whiteAttributes[.foregroundColor] = NSColor.white
                    currentLineText.draw(in: textRect, withAttributes: whiteAttributes)
                    
                    // Apple Music fade effect using compositing
                    let fadeWidth: CGFloat = 20
                    
                    // 1. Clear everything after currentX
                    NSGraphicsContext.current?.compositingOperation = .copy
                    NSColor.clear.setFill()
                    NSRect(x: currentX, y: 0, width: animatedWidth - currentX, height: 20).fill()
                    
                    // 2. Fade the edge using destinationIn
                    NSGraphicsContext.current?.compositingOperation = .destinationIn
                    if let gradient = NSGradient(colors: [.white, .clear]) {
                        gradient.draw(from: NSPoint(x: currentX - fadeWidth, y: 0), to: NSPoint(x: currentX, y: 0), options: [])
                    }
                    
                    whiteImage.unlockFocus()
                    
                    // Draw the final white masked image over the base image
                    NSGraphicsContext.current?.saveGraphicsState()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                    whiteImage.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
                
                let totalSparkleDuration = 5.5
                let sparkleTime = Date().timeIntervalSince(trackChangedTime)
                
                let isSparkling = lyricsService.isLoading || (sparkleTime < totalSparkleDuration && currentLineText == track.name)
                
                if isSparkling {
                    let cycleTime = lyricsService.isLoading ? sparkleTime.truncatingRemainder(dividingBy: totalSparkleDuration) : sparkleTime
                    let textW = textSize.width
                    
                    var seed = abs(currentLineText.hashValue)
                    func randomFloat() -> CGFloat {
                        seed = (seed &* 1664525) &+ 1013904223
                        return CGFloat(abs(seed) % 1000) / 1000.0
                    }
                    
                    for _ in 0..<18 {
                        let rx = randomFloat()
                        let ry = randomFloat()
                        let rt = randomFloat()
                        let rs = randomFloat()
                        let rd = randomFloat()
                        
                        let delay = Double(rt) * 4.5 // 0 to 4.5s
                        let duration = 0.5 + Double(rd) * 0.7 // 0.5 to 1.2s
                        let center = NSPoint(x: 8.0 + textW * rx, y: 6.0 + 8.0 * ry) // Constrained to avoid clipping
                        let sizeMult = 0.7 + rs * 0.5 // 0.7 to 1.2
                        
                        let sp = max(0, min(1, (cycleTime - delay) / duration))
                        if sp > 0 && sp < 1 {
                            let s = sin(sp * .pi) * 5.0 * sizeMult // Max size ~6.0
                            let alpha = sin(sp * .pi)
                            
                            NSGraphicsContext.current?.saveGraphicsState()
                            let shadow = NSShadow()
                            shadow.shadowColor = NSColor.white.withAlphaComponent(alpha)
                            shadow.shadowBlurRadius = 4
                            shadow.shadowOffset = .zero
                            shadow.set()
                            
                            let path = NSBezierPath()
                            path.move(to: NSPoint(x: center.x, y: center.y + s))
                            path.curve(to: NSPoint(x: center.x + s, y: center.y), controlPoint1: NSPoint(x: center.x, y: center.y + s * 0.3), controlPoint2: NSPoint(x: center.x + s * 0.3, y: center.y))
                            path.curve(to: NSPoint(x: center.x, y: center.y - s), controlPoint1: NSPoint(x: center.x + s * 0.3, y: center.y), controlPoint2: NSPoint(x: center.x, y: center.y - s * 0.3))
                            path.curve(to: NSPoint(x: center.x - s, y: center.y), controlPoint1: NSPoint(x: center.x, y: center.y - s * 0.3), controlPoint2: NSPoint(x: center.x - s * 0.3, y: center.y))
                            path.curve(to: NSPoint(x: center.x, y: center.y + s), controlPoint1: NSPoint(x: center.x - s * 0.3, y: center.y), controlPoint2: NSPoint(x: center.x, y: center.y + s * 0.3))
                            
                            NSColor.white.withAlphaComponent(alpha).setFill()
                            path.fill()
                            NSGraphicsContext.current?.restoreGraphicsState()
                        }
                    }
                }
                
                lyricsImage.unlockFocus()
                lyricsButton.image = lyricsImage
                lastRenderedLyricsText = currentLineText  // cache for skip-redraw
            } else {
                lyricsButton.image = nil
            }
            
            // --- 2. ART & WAVEFORM UPDATING (Right Item, Fixed Width) ---
            if cachedAlbumArtURL != track.artworkURL {
                cachedAlbumArtURL = track.artworkURL
                cachedAlbumArtImage = nil // Reset cache
                
                if let urlString = track.artworkURL, let url = URL(string: urlString) {
                    URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                        if let data = data, let image = NSImage(data: data) {
                            Task {
                                let roundedImage = await MainActor.run { self?.roundCorners(of: image, size: NSSize(width: 20, height: 20), radius: 4) }
                                let blurred = await Task.detached { () -> NSImage? in
                                    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                                    let ciImage = CIImage(cgImage: cgImage)
                                    let blurFilter = CIFilter(name: "CIGaussianBlur")
                                    blurFilter?.setValue(ciImage, forKey: kCIInputImageKey)
                                    blurFilter?.setValue(60.0, forKey: kCIInputRadiusKey)
                                    guard var blurred = blurFilter?.outputImage else { return nil }
                                    let exposureFilter = CIFilter(name: "CIExposureAdjust")
                                    exposureFilter?.setValue(blurred, forKey: kCIInputImageKey)
                                    exposureFilter?.setValue(1.5, forKey: kCIInputEVKey)
                                    if let exposed = exposureFilter?.outputImage { blurred = exposed }
                                    let colorFilter = CIFilter(name: "CIColorControls")
                                    colorFilter?.setValue(blurred, forKey: kCIInputImageKey)
                                    colorFilter?.setValue(1.6, forKey: kCIInputSaturationKey)
                                    colorFilter?.setValue(0.05, forKey: kCIInputBrightnessKey)
                                    if let vivid = colorFilter?.outputImage { blurred = vivid }
                                    let context = CIContext()
                                    guard let resultCG = context.createCGImage(blurred, from: ciImage.extent) else { return nil }
                                    return NSImage(cgImage: resultCG, size: NSSize(width: 74, height: 20))
                                }.value
                                await MainActor.run {
                                    self?.cachedBlurredAlbumArtImage = blurred ?? roundedImage
                                    self?.cachedAlbumArtImage = roundedImage
                                }
                            }
                        }
                    }.resume()
                } else {
                    let fallback = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
                    fallback?.isTemplate = true
                    cachedAlbumArtImage = fallback
                    cachedBlurredAlbumArtImage = fallback
                }
            }
            
            let waveformBars = UserDefaults.standard.integer(forKey: "waveformBars")
            let barCount = waveformBars
            let barW: CGFloat = 2.0
            let barSp: CGFloat = 1.5
            let vizWidth: CGFloat = barCount > 0 ? CGFloat(barCount) * (barW + barSp) : 0
            let artGap: CGFloat = 16.0 // Matched to system gap
            let artWidth: CGFloat = showAlbumArt ? 20.0 : 0
            
            var combinedWidth: CGFloat = 20.0
            if cachedAlbumArtImage != nil {
                if barCount > 0 && showAlbumArt {
                    combinedWidth = vizWidth + artGap + artWidth
                } else if barCount > 0 {
                    combinedWidth = vizWidth
                } else if showAlbumArt {
                    combinedWidth = artWidth
                } else {
                    combinedWidth = 1.0
                }
            }
            
            let combinedImage = NSImage(size: NSSize(width: combinedWidth, height: 20))
            combinedImage.isTemplate = false
            combinedImage.lockFocus()
            
            if spotify.isPlaying && cachedAlbumArtImage != nil && barCount > 0 {
                let startX: CGFloat = 0
                let totalAmps = audioAnalyzer.amplitudes.count
                let clipPath = NSBezierPath()
                let motionClipPath = NSBezierPath()
                
                for i in 0..<barCount {
                    let ampIndex = totalAmps > 0 ? (i * totalAmps / barCount) : 0
                    let rawAmp = (totalAmps > ampIndex) ? audioAnalyzer.amplitudes[ampIndex] : 0.05
                    let height = max(3.0, rawAmp * 20.0)
                    let y = (20.0 - height) / 2.0
                    let rect = NSRect(x: startX + CGFloat(i) * (barW + barSp), y: y, width: barW, height: height)
                    clipPath.append(NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1))
                    
                    let lastAmp = lastAmplitudes.count > i ? lastAmplitudes[i] : 0.05
                    let lastHeight = max(3.0, lastAmp * 20.0)
                    let lastY = (20.0 - lastHeight) / 2.0
                    let lastRect = NSRect(x: startX + CGFloat(i) * (barW + barSp), y: lastY, width: barW, height: lastHeight)
                    motionClipPath.append(NSBezierPath(roundedRect: lastRect, xRadius: 1, yRadius: 1))
                }
                
                if totalAmps > 0 {
                    lastAmplitudes = (0..<barCount).map { i in
                        return audioAnalyzer.amplitudes[(i * totalAmps / barCount)]
                    }
                }
                
                NSGraphicsContext.current?.saveGraphicsState()
                motionClipPath.addClip()
                if let blurImage = cachedBlurredAlbumArtImage, !blurImage.isTemplate {
                    let fillRect = NSRect(x: startX, y: 0, width: vizWidth, height: 20)
                    blurImage.draw(in: fillRect, from: NSRect(origin: .zero, size: blurImage.size), operation: .copy, fraction: 0.5)
                    NSColor.white.withAlphaComponent(0.25).setFill()
                    motionClipPath.fill()
                } else {
                    NSColor.white.withAlphaComponent(0.4).set()
                    motionClipPath.fill()
                }
                NSGraphicsContext.current?.restoreGraphicsState()
                
                // Cast the glowing shadow behind the main bars
                NSGraphicsContext.current?.saveGraphicsState()
                
                // 1. Outer Bloom
                let outerShadow = NSShadow()
                outerShadow.shadowColor = NSColor.white.withAlphaComponent(0.5)
                outerShadow.shadowOffset = .zero
                outerShadow.shadowBlurRadius = 6.0
                outerShadow.set()
                NSColor.clear.setFill() // Only cast shadow, don't fill yet
                clipPath.fill()
                
                // 2. Inner Intense Glow
                let innerShadow = NSShadow()
                innerShadow.shadowColor = NSColor.white.withAlphaComponent(0.9)
                innerShadow.shadowOffset = .zero
                innerShadow.shadowBlurRadius = 2.0
                innerShadow.set()
                NSColor.clear.setFill() // Don't pre-fill with white so colors can shine
                clipPath.fill()
                
                NSGraphicsContext.current?.restoreGraphicsState()
                
                // Draw the textured/bright bars inside the clip
                NSGraphicsContext.current?.saveGraphicsState()
                clipPath.addClip()
                if let blurImage = cachedBlurredAlbumArtImage, !blurImage.isTemplate {
                    let fillRect = NSRect(x: startX, y: 0, width: vizWidth, height: 20)
                    blurImage.draw(in: fillRect, from: NSRect(origin: .zero, size: blurImage.size), operation: .copy, fraction: 1.0)
                    NSColor.white.withAlphaComponent(0.15).setFill() // Tiny bit of white just to ensure contrast, but let the colors pop!
                    clipPath.fill()
                } else {
                    NSColor.white.set()
                    clipPath.fill()
                }
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            
            if let art = cachedAlbumArtImage, showAlbumArt {
                let artX = combinedWidth - artWidth
                art.draw(at: NSPoint(x: artX, y: 0), from: NSRect(origin: .zero, size: art.size), operation: .copy, fraction: 1.0)
            }
            
            combinedImage.unlockFocus()
            artButton.image = combinedImage
            artButton.needsDisplay = true
            
        } else {
            // No track playing
            if let artButton = self.artStatusItem?.button {
                if artButton.image?.name() != NSImage.Name("music.note") {
                    let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
                    img?.isTemplate = true
                    artButton.image = img
                }
            }
            if let lyricsButton = self.lyricsStatusItem?.button {
                lyricsButton.image = nil
            }
        }
    }
}
