import AppKit
import QuartzCore

// MARK: - GPU-Native 60 FPS Menu Bar Renderer (Zero lockFocus, Zero Per-Frame Bitmap Uploads)
@MainActor
final class MenuBarCanvasView: NSView {
    nonisolated private static let stripHeight: CGFloat = 22.0
    private let stripLayer = CALayer()

    // 1. Lyrics Subsystem
    private let lyricsClipLayer = CALayer()
    private let lyricsEdgeMask = CAGradientLayer()

    private final class TextLineSlot {
        let container = CALayer()
        let dimLayer = CALayer()
        let litLayer = CALayer()
        let maskContainer = CALayer()
        let maskSolid = CALayer()
        let maskFeather = CAGradientLayer()

        var textWidth: CGFloat = 0
        var lastLeadX: CGFloat = -24.0
        var lastShowHighlight: Bool = false

        init() {
            let h = MenuBarCanvasView.stripHeight
            container.anchorPoint = .zero
            container.masksToBounds = false

            dimLayer.anchorPoint = .zero
            dimLayer.opacity = 0.40
            dimLayer.contentsGravity = .bottomLeft

            litLayer.anchorPoint = .zero
            litLayer.opacity = 1.0
            litLayer.contentsGravity = .bottomLeft

            maskContainer.anchorPoint = .zero
            maskContainer.masksToBounds = false

            maskSolid.anchorPoint = .zero
            maskSolid.backgroundColor = NSColor.white.cgColor
            maskSolid.frame = CGRect(x: -2400, y: 0, width: 2400, height: h)

            maskFeather.anchorPoint = .zero
            maskFeather.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
            maskFeather.startPoint = CGPoint(x: 0.0, y: 0.5)
            maskFeather.endPoint = CGPoint(x: 1.0, y: 0.5)
            maskFeather.frame = CGRect(x: 0, y: 0, width: 24, height: h)

            maskContainer.addSublayer(maskSolid)
            maskContainer.addSublayer(maskFeather)
            litLayer.mask = maskContainer

            container.addSublayer(dimLayer)
            container.addSublayer(litLayer)
        }

        func apply(cgImage: CGImage?, size: NSSize, scale: CGFloat) {
            let h = MenuBarCanvasView.stripHeight
            self.textWidth = size.width
            dimLayer.contentsScale = scale
            litLayer.contentsScale = scale
            dimLayer.contents = cgImage
            litLayer.contents = cgImage
            let rect = CGRect(x: 0, y: 0, width: ceil(size.width) + 4, height: h)
            dimLayer.frame = rect
            litLayer.frame = rect
        }

        func copyState(from other: TextLineSlot) {
            self.textWidth = other.textWidth
            self.lastLeadX = other.lastLeadX
            self.lastShowHighlight = other.lastShowHighlight
            dimLayer.contents = other.dimLayer.contents
            litLayer.contents = other.litLayer.contents
            dimLayer.contentsScale = other.dimLayer.contentsScale
            litLayer.contentsScale = other.litLayer.contentsScale
            dimLayer.frame = other.dimLayer.frame
            litLayer.frame = other.litLayer.frame
            litLayer.isHidden = !other.lastShowHighlight
            maskContainer.position = CGPoint(x: other.lastLeadX, y: 0)
        }

        func clear() {
            textWidth = 0
            lastLeadX = -24.0
            lastShowHighlight = false
            dimLayer.contents = nil
            litLayer.contents = nil
            container.isHidden = true
        }
    }

    private let activeSlot = TextLineSlot()
    private let outgoingSlot = TextLineSlot()
    private let interludeContainer = CALayer()
    private var interludeStarLayers: [CAShapeLayer] = []
    private var sparkleLayers: [CAShapeLayer] = []

    // Shared precomputed unit 4-point star CGPath centered at (0, 0)
    private static let unitStarPath: CGPath = {
        let p = CGMutablePath()
        let c: CGFloat = 0.3
        p.move(to: CGPoint(x: 0, y: 1))
        p.addCurve(to: CGPoint(x: 1, y: 0), control1: CGPoint(x: 0, y: c), control2: CGPoint(x: c, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: -1), control1: CGPoint(x: c, y: 0), control2: CGPoint(x: 0, y: -c))
        p.addCurve(to: CGPoint(x: -1, y: 0), control1: CGPoint(x: 0, y: -c), control2: CGPoint(x: -c, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: 1), control1: CGPoint(x: -c, y: 0), control2: CGPoint(x: 0, y: c))
        p.closeSubpath()
        return p
    }()

    // 2. Waveform Subsystem
    private let waveformGradientLayer = CAGradientLayer()
    private let waveformMaskContainer = CALayer()
    private var barLayers: [CALayer] = []
    private var currentBarCount: Int = 0
    private var lastTopColorCG: CGColor?
    private var lastBottomColorCG: CGColor?

    // 3. Album Art Subsystem
    private let artContainerLayer = CALayer()
    private let prevArtLayer = CALayer()
    private let currArtLayer = CALayer()
    private var hasCurrArt: Bool = false
    private var hasPrevArt: Bool = false

    // Rasterization State Caches (Updated ONLY on content/theme/scale change)
    private var backingScale: CGFloat = 2.0
    private var lastCanvasWidth: CGFloat = -1
    private var lastText: String = ""
    private var lastIsDark: Bool? = nil
    private var lastRasterizedScale: CGFloat = 0
    private var lastArtKey: String = ""
    private var lastArtIsFallback: Bool = false
    private var lastFallbackIsDark: Bool? = nil
    private var sourceArtNSImage: NSImage? = nil

    var onAppearanceOrScaleChanged: (() -> Void)?

    private let menuBarFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    private lazy var textAttributes: [NSAttributedString.Key: Any] = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byTruncatingTail
        return [.font: menuBarFont, .paragraphStyle: paragraphStyle]
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHierarchy()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Clicks pass directly through to NSStatusBarButton
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceOrScaleChanged?()
    }

    private func updateBackingScale() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        guard abs(newScale - backingScale) > 0.01 else { return }
        backingScale = newScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyContentsScale(newScale)
        if let srcImg = sourceArtNSImage {
            let isDark = lastFallbackIsDark ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let resolvedColor = isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)
            currArtLayer.contents = lastArtIsFallback
                ? rasterizeTemplateImage(srcImg, tintColor: resolvedColor, size: NSSize(width: 20, height: 20), scale: newScale)
                : rasterizeArtImage(srcImg, size: NSSize(width: 20, height: 20), scale: newScale)
            currArtLayer.contentsScale = newScale
        }
        CATransaction.commit()
        onAppearanceOrScaleChanged?()
    }

    private func applyContentsScale(_ scale: CGFloat) {
        self.layer?.contentsScale = scale
        stripLayer.contentsScale = scale
        lyricsClipLayer.contentsScale = scale
        lyricsEdgeMask.contentsScale = scale
        activeSlot.dimLayer.contentsScale = scale
        activeSlot.litLayer.contentsScale = scale
        activeSlot.maskFeather.contentsScale = scale
        outgoingSlot.dimLayer.contentsScale = scale
        outgoingSlot.litLayer.contentsScale = scale
        outgoingSlot.maskFeather.contentsScale = scale
        for s in interludeStarLayers { s.contentsScale = scale }
        for s in sparkleLayers { s.contentsScale = scale }
        waveformGradientLayer.contentsScale = scale
        waveformMaskContainer.contentsScale = scale
        for b in barLayers { b.contentsScale = scale }
        artContainerLayer.contentsScale = scale
        prevArtLayer.contentsScale = scale
        currArtLayer.contentsScale = scale
    }

    private func setupHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        stripLayer.anchorPoint = .zero
        stripLayer.isGeometryFlipped = false
        stripLayer.masksToBounds = false
        layer?.addSublayer(stripLayer)

        // 1. Lyrics Clip Container
        lyricsClipLayer.anchorPoint = .zero
        lyricsClipLayer.masksToBounds = true
        lyricsEdgeMask.anchorPoint = .zero
        lyricsEdgeMask.colors = [
            NSColor.clear.cgColor,
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.clear.cgColor
        ]
        lyricsEdgeMask.startPoint = CGPoint(x: 0.0, y: 0.5)
        lyricsEdgeMask.endPoint = CGPoint(x: 1.0, y: 0.5)
        lyricsClipLayer.mask = lyricsEdgeMask

        outgoingSlot.container.isHidden = true
        activeSlot.container.isHidden = true
        lyricsClipLayer.addSublayer(outgoingSlot.container)
        lyricsClipLayer.addSublayer(activeSlot.container)

        // Interlude 3 stars (initialized with explicit fillColor!)
        interludeContainer.anchorPoint = .zero
        interludeContainer.isHidden = true
        for _ in 0..<3 {
            let star = CAShapeLayer()
            star.path = Self.unitStarPath
            star.fillColor = NSColor.white.cgColor
            star.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            star.bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
            interludeContainer.addSublayer(star)
            interludeStarLayers.append(star)
        }
        lyricsClipLayer.addSublayer(interludeContainer)

        // Track-change Sparkles (10 lightweight GPU shape layers)
        for _ in 0..<10 {
            let sp = CAShapeLayer()
            sp.path = Self.unitStarPath
            sp.fillColor = NSColor.white.cgColor
            sp.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            sp.bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
            sp.isHidden = true
            lyricsClipLayer.addSublayer(sp)
            sparkleLayers.append(sp)
        }
        stripLayer.addSublayer(lyricsClipLayer)

        // 2. Waveform Gradient Container
        waveformGradientLayer.anchorPoint = .zero
        waveformGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        waveformGradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        waveformMaskContainer.anchorPoint = .zero
        waveformGradientLayer.mask = waveformMaskContainer
        waveformGradientLayer.isHidden = true
        stripLayer.addSublayer(waveformGradientLayer)

        // 3. Album Art Container (20x20, 4pt continuous corners)
        artContainerLayer.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        artContainerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        artContainerLayer.cornerRadius = 4.0
        artContainerLayer.cornerCurve = .continuous
        artContainerLayer.masksToBounds = true

        prevArtLayer.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        prevArtLayer.contentsGravity = .resizeAspectFill
        prevArtLayer.opacity = 0.0

        currArtLayer.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        currArtLayer.contentsGravity = .resizeAspectFill
        currArtLayer.opacity = 1.0

        artContainerLayer.addSublayer(prevArtLayer)
        artContainerLayer.addSublayer(currArtLayer)
        artContainerLayer.isHidden = true
        stripLayer.addSublayer(artContainerLayer)

        applyContentsScale(backingScale)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = Self.stripHeight
        let yCentered = floor((bounds.height - h) / 2.0)
        stripLayer.frame = CGRect(x: 0, y: max(0, yCentered), width: bounds.width, height: h)
        CATransaction.commit()
    }

    // MARK: - Artwork Upload (Called ONLY on track/artwork/appearance change)

    func setArtwork(
        _ image: NSImage?,
        artKey: String,
        isFallbackSymbol: Bool,
        isDark: Bool,
        crossfadePrevious: Bool
    ) {
        let needsFallbackTintUpdate = isFallbackSymbol && lastArtIsFallback && (lastFallbackIsDark != isDark)
        guard artKey != lastArtKey || needsFallbackTintUpdate else { return }

        let previousContents = hasCurrArt ? currArtLayer.contents : nil
        lastArtKey = artKey
        lastArtIsFallback = isFallbackSymbol
        lastFallbackIsDark = isDark
        sourceArtNSImage = image

        let resolvedColor = isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)
        let cgImg: CGImage?
        if let image = image {
            if isFallbackSymbol {
                cgImg = rasterizeTemplateImage(image, tintColor: resolvedColor, size: NSSize(width: 20, height: 20), scale: backingScale)
            } else {
                cgImg = rasterizeArtImage(image, size: NSSize(width: 20, height: 20), scale: backingScale)
            }
        } else {
            cgImg = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if crossfadePrevious, let prev = previousContents {
            prevArtLayer.contents = prev
            prevArtLayer.contentsScale = backingScale
            hasPrevArt = true
        } else {
            prevArtLayer.contents = nil
            prevArtLayer.opacity = 0.0
            hasPrevArt = false
        }
        currArtLayer.contents = cgImg
        currArtLayer.contentsScale = backingScale
        hasCurrArt = (cgImg != nil)
        CATransaction.commit()
    }

    func reset() {
        lastText = ""
        lastArtKey = ""
        lastIsDark = nil
        lastFallbackIsDark = nil
        hasCurrArt = false
        hasPrevArt = false
        sourceArtNSImage = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activeSlot.clear()
        outgoingSlot.clear()
        currArtLayer.contents = nil
        prevArtLayer.contents = nil
        interludeContainer.isHidden = true
        for sp in sparkleLayers { sp.isHidden = true }
        waveformGradientLayer.isHidden = true
        artContainerLayer.isHidden = true
        CATransaction.commit()
    }

    // MARK: - 60 FPS Frame Render (GPU Properties Only)

    func renderFrame(
        currentLineText: String,
        textSize: NSSize,
        glowPad: CGFloat,
        showLyrics: Bool,
        lyricsX: CGFloat,
        canvasWidth: CGFloat,
        marqueeOffset: CGFloat,
        oldMarqueeOffset: CGFloat,
        transitionProgress: CGFloat,
        progress: Double,
        wordLeadX: CGFloat?,
        animatedOrbAlpha: CGFloat,
        isDark: Bool,
        isSparkling: Bool,
        sparkleCycleTime: Double,
        nowTime: TimeInterval,
        showWaveform: Bool,
        vizX: CGFloat,
        vizWidth: CGFloat,
        barHeights: [CGFloat],
        barW: CGFloat,
        barSp: CGFloat,
        waveformTheme: WaveformThemeModel,
        showAlbumArt: Bool,
        artX: CGFloat,
        artScale: CGFloat,
        popElapsed: TimeInterval?,
        artOpacity: CGFloat
    ) {
        let stripH = Self.stripHeight
        let primaryColor = isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)
        let themeChanged = (lastIsDark != isDark)
        let scaleChanged = abs(lastRasterizedScale - backingScale) > 0.01

        // Check if text or theme changed — ONLY then rasterize text ONCE into CGImage
        let textChanged = (currentLineText != lastText)
        let isInterlude = currentLineText.contains("✦")

        var newlyRasterized: (CGImage, NSSize)? = nil
        if showLyrics && !isInterlude && (textChanged || themeChanged || scaleChanged) {
            newlyRasterized = rasterizeTextCGImage(currentLineText, textSize: textSize, color: primaryColor, scale: backingScale)
        }

        // Ensure fallback play.fill symbol updates tint if system appearance switches light <-> dark
        if lastArtIsFallback && lastFallbackIsDark != isDark, let fallbackImg = sourceArtNSImage {
            let tinted = rasterizeTemplateImage(fallbackImg, tintColor: primaryColor, size: NSSize(width: 20, height: 20), scale: backingScale)
            lastFallbackIsDark = isDark
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            currArtLayer.contents = tinted
            CATransaction.commit()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if stripLayer.superlayer == nil {
            self.layer?.addSublayer(stripLayer)
        }
        let yCentered = floor((bounds.height - stripH) / 2.0)
        stripLayer.frame = CGRect(x: 0, y: max(0, yCentered), width: max(bounds.width, artX + 24), height: stripH)

        // --- 1. LYRICS LAYER UPDATE ---
        if showLyrics && canvasWidth > 2 {
            lyricsClipLayer.isHidden = false
            lyricsClipLayer.frame = CGRect(x: lyricsX, y: 0, width: canvasWidth, height: stripH)

            if abs(canvasWidth - lastCanvasWidth) > 0.25 {
                lastCanvasWidth = canvasWidth
                lyricsEdgeMask.frame = CGRect(x: 0, y: 0, width: canvasWidth, height: stripH)
                if canvasWidth > 16 {
                    let fadeFrac = NSNumber(value: Double(min(0.45, 16.0 / canvasWidth)))
                    let endFrac = NSNumber(value: Double(max(0.55, 1.0 - 16.0 / canvasWidth)))
                    lyricsEdgeMask.locations = [0.0, fadeFrac, endFrac, 1.0]
                    if lyricsClipLayer.mask == nil {
                        lyricsClipLayer.mask = lyricsEdgeMask
                    }
                } else {
                    lyricsClipLayer.mask = nil
                }
            }

            if textChanged {
                if activeSlot.dimLayer.contents != nil {
                    outgoingSlot.copyState(from: activeSlot)
                } else {
                    outgoingSlot.clear()
                }
                if isInterlude {
                    activeSlot.clear()
                } else if let (cgImg, sz) = newlyRasterized {
                    activeSlot.apply(cgImage: cgImg, size: sz, scale: backingScale)
                } else {
                    activeSlot.clear()
                }
                lastText = currentLineText
                lastIsDark = isDark
                lastRasterizedScale = backingScale
            } else if (themeChanged || scaleChanged) {
                if !isInterlude {
                    if let (cgImg, sz) = newlyRasterized {
                        activeSlot.apply(cgImage: cgImg, size: sz, scale: backingScale)
                    } else {
                        activeSlot.clear()
                    }
                }
                lastIsDark = isDark
                lastRasterizedScale = backingScale
            }

            let t = transitionProgress
            let easedT = 1.0 - pow(1.0 - t, 3.0)
            let yOffsetOld = easedT * 14.0
            let alphaOld = max(0.0, 1.0 - easedT)
            let yOffsetNew = -14.0 + easedT * 14.0
            let alphaNew = easedT

            // Outgoing line sliding up & fading out
            if transitionProgress < 1.0 && outgoingSlot.dimLayer.contents != nil && alphaOld > 0.005 {
                outgoingSlot.container.isHidden = false
                outgoingSlot.container.position = CGPoint(x: glowPad + oldMarqueeOffset, y: yOffsetOld)
                outgoingSlot.container.opacity = Float(alphaOld)
            } else {
                outgoingSlot.container.isHidden = true
            }

            // Active line / Interlude
            if isInterlude {
                activeSlot.container.isHidden = true
                interludeContainer.isHidden = false
                interludeContainer.frame = CGRect(x: 0, y: 0, width: canvasWidth, height: stripH)

                let starCount = 3
                let spacing: CGFloat = 16.0
                let startX = (canvasWidth - CGFloat(starCount - 1) * spacing) / 2.0
                let centerY: CGFloat = (stripH / 2.0) + yOffsetNew
                let phaseTime = nowTime * 3.8
                let primaryCG = primaryColor.cgColor

                for sIdx in 0..<starCount {
                    let phase = Double(sIdx) * 0.8
                    let pulse = (sin(phaseTime + phase) + 1.0) * 0.5
                    let s = (3.0 + CGFloat(pulse) * 2.2) * alphaNew
                    let alpha = Float((0.50 + CGFloat(pulse) * 0.50) * alphaNew)
                    let star = interludeStarLayers[sIdx]
                    star.position = CGPoint(x: startX + CGFloat(sIdx) * spacing, y: centerY)
                    star.transform = CATransform3DMakeScale(max(0.01, s), max(0.01, s), 1.0)
                    star.opacity = alpha
                    star.fillColor = primaryCG
                }
            } else {
                interludeContainer.isHidden = true
                if activeSlot.dimLayer.contents != nil {
                    activeSlot.container.isHidden = false
                    activeSlot.container.position = CGPoint(x: glowPad + marqueeOffset, y: yOffsetNew)
                    activeSlot.container.opacity = Float(alphaNew)

                    let showHighlight = (progress > 0 || animatedOrbAlpha > 0.01)
                    activeSlot.lastShowHighlight = showHighlight
                    if showHighlight {
                        activeSlot.litLayer.isHidden = false
                        let fadeWidth: CGFloat = 24.0
                        let leadX: CGFloat
                        if let exactX = wordLeadX {
                            leadX = exactX
                        } else {
                            let safeW = ceil(activeSlot.textWidth) + 4
                            leadX = (safeW + fadeWidth) * CGFloat(progress) - fadeWidth
                        }
                        activeSlot.lastLeadX = leadX
                        activeSlot.maskContainer.position = CGPoint(x: leadX, y: 0)
                    } else {
                        activeSlot.litLayer.isHidden = true
                    }
                } else {
                    activeSlot.container.isHidden = true
                }
            }

            // Sparkles (10 GPU shape layers, zero CPU blur)
            if isSparkling {
                let textW = textSize.width
                var seed = abs(currentLineText.hashValue)
                func randomFloat() -> CGFloat {
                    seed = (seed &* 1664525) &+ 1013904223
                    return CGFloat(abs(seed) % 1000) / 1000.0
                }
                let primaryCG = primaryColor.cgColor
                for spLayer in sparkleLayers {
                    let rx = randomFloat()
                    let ry = randomFloat()
                    let rt = randomFloat()
                    let rs = randomFloat()
                    let rd = randomFloat()

                    let delay = Double(rt) * 4.5
                    let duration = 0.5 + Double(rd) * 0.7
                    let sp = max(0, min(1, (sparkleCycleTime - delay) / duration))
                    if sp > 0 && sp < 1 {
                        let s = sin(sp * .pi) * 4.5 * (0.7 + rs * 0.5)
                        let alpha = Float(sin(sp * .pi))
                        spLayer.isHidden = false
                        spLayer.position = CGPoint(x: glowPad + marqueeOffset + textW * rx, y: 7.0 + 8.0 * ry)
                        spLayer.transform = CATransform3DMakeScale(max(0.01, s), max(0.01, s), 1.0)
                        spLayer.opacity = alpha
                        spLayer.fillColor = primaryCG
                    } else {
                        spLayer.isHidden = true
                    }
                }
            } else {
                for spLayer in sparkleLayers where !spLayer.isHidden {
                    spLayer.isHidden = true
                }
            }
        } else {
            lyricsClipLayer.isHidden = true
        }

        // --- 2. WAVEFORM LAYER UPDATE ---
        if showWaveform && vizWidth > 0 && !barHeights.isEmpty {
            let count = barHeights.count
            waveformGradientLayer.isHidden = false
            waveformGradientLayer.frame = CGRect(x: vizX, y: 1.0, width: vizWidth, height: 20)
            waveformMaskContainer.frame = CGRect(x: 0, y: 0, width: vizWidth, height: 20)

            let topCG = waveformTheme.topColor.cgColor
            let bottomCG = waveformTheme.bottomColor.cgColor
            if lastTopColorCG != topCG || lastBottomColorCG != bottomCG {
                waveformGradientLayer.colors = [bottomCG, topCG]
                lastTopColorCG = topCG
                lastBottomColorCG = bottomCG
            }

            if count != currentBarCount {
                for b in barLayers { b.removeFromSuperlayer() }
                barLayers.removeAll(keepingCapacity: true)
                for i in 0..<count {
                    let bar = CALayer()
                    bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                    bar.backgroundColor = NSColor.white.cgColor
                    bar.cornerRadius = barW / 2.0
                    bar.contentsScale = backingScale
                    bar.position = CGPoint(x: CGFloat(i) * (barW + barSp) + barW * 0.5, y: 10.0)
                    bar.bounds = CGRect(x: 0, y: 0, width: barW, height: 2.5)
                    waveformMaskContainer.addSublayer(bar)
                    barLayers.append(bar)
                }
                currentBarCount = count
            }

            for i in 0..<count {
                let h = barHeights[i]
                barLayers[i].bounds = CGRect(x: 0, y: 0, width: barW, height: h)
            }
        } else {
            waveformGradientLayer.isHidden = true
        }

        // --- 3. ALBUM ART LAYER UPDATE ---
        if showAlbumArt && hasCurrArt {
            artContainerLayer.isHidden = false
            artContainerLayer.position = CGPoint(x: artX + 10.0, y: stripH / 2.0)
            artContainerLayer.transform = CATransform3DMakeScale(artScale, artScale, 1.0)

            let popDuration: TimeInterval = 0.75
            if let elapsed = popElapsed, elapsed < popDuration, hasPrevArt {
                let t = CGFloat(elapsed / popDuration)
                let outAlpha = Float(max(0.0, 1.0 - t * 1.5) * artOpacity)
                let inAlpha = Float(min(1.0, t * 1.3) * artOpacity)
                prevArtLayer.opacity = outAlpha
                currArtLayer.opacity = inAlpha
            } else {
                prevArtLayer.opacity = 0.0
                currArtLayer.opacity = Float(artOpacity)
            }
        } else {
            artContainerLayer.isHidden = true
        }

        CATransaction.commit()
    }

    // MARK: - Direct CGContext Rasterizers (Zero lockFocus)

    private func rasterizeTextCGImage(_ text: String, textSize: NSSize, color: NSColor, scale: CGFloat) -> (CGImage, NSSize)? {
        let safeW = ceil(textSize.width) + 4.0
        guard safeW > 4.0 else { return nil }
        let stripH = Self.stripHeight
        let pixelW = max(1, Int(ceil(safeW * scale)))
        let pixelH = max(1, Int(ceil(stripH * scale)))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: pixelW,
                height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(true)
        ctx.setShouldSubpixelQuantizeFonts(false)

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        var attrs = textAttributes
        attrs[.foregroundColor] = color
        let drawY = max(0, (stripH - textSize.height) / 2.0)
        (text as NSString).draw(at: NSPoint(x: 0, y: drawY), withAttributes: attrs)

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return nil }
        return (cgImage, NSSize(width: textSize.width, height: stripH))
    }

    private func rasterizeArtImage(_ image: NSImage, size: NSSize, scale: CGFloat) -> CGImage? {
        let pixelW = max(1, Int(ceil(size.width * scale)))
        let pixelH = max(1, Int(ceil(size.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: pixelW,
                height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        nsCtx.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func rasterizeTemplateImage(_ image: NSImage, tintColor: NSColor, size: NSSize, scale: CGFloat) -> CGImage? {
        let pixelW = max(1, Int(ceil(size.width * scale)))
        let pixelH = max(1, Int(ceil(size.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: pixelW,
                height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let imgSize = image.size
        let aspect = imgSize.width / max(1, imgSize.height)
        let drawSize: NSSize = aspect >= 1
            ? NSSize(width: size.width * 0.75, height: (size.width * 0.75) / aspect)
            : NSSize(width: (size.height * 0.75) * aspect, height: size.height * 0.75)
        let drawOrigin = NSPoint(x: (size.width - drawSize.width) / 2.0, y: (size.height - drawSize.height) / 2.0)
        let drawRect = NSRect(origin: drawOrigin, size: drawSize)

        image.draw(in: drawRect, from: NSRect(origin: .zero, size: imgSize), operation: .copy, fraction: 1.0)
        tintColor.setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceIn)

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
