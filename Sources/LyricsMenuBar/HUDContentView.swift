import AppKit
import QuartzCore

private func rasterizeRetinaSymbol(
    _ name: String,
    pointSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    canvasSize: NSSize,
    scale: CGFloat
) -> CGImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else {
        return nil
    }
    let safeScale = max(1.0, scale)
    let pxW = max(1, Int(ceil(canvasSize.width * safeScale)))
    let pxH = max(1, Int(ceil(canvasSize.height * safeScale)))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ) else { return nil }
    ctx.scaleBy(x: safeScale, y: safeScale)
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    let imgSz = sym.size
    let fit = min(1.0, min(canvasSize.width / max(1.0, imgSz.width), canvasSize.height / max(1.0, imgSz.height)))
    let drawW = imgSz.width * fit
    let drawH = imgSz.height * fit
    let rect = NSRect(
        x: (canvasSize.width - drawW) / 2.0,
        y: (canvasSize.height - drawH) / 2.0,
        width: drawW,
        height: drawH
    )
    sym.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
    color.setFill()
    NSRect(origin: .zero, size: canvasSize).fill(using: .sourceIn)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

// MARK: - Tactile Circular Control Button (AppKit + CASpringAnimation)

@MainActor
private final class TactileCircleButton: NSView {
    private let contentLayer = CALayer()
    private let bgLayer = CALayer()
    private let iconLayer = CALayer()
    private let size: CGFloat
    private let iconSize: CGFloat
    private var symbolName: String
    private var isHovered = false
    private var isPressed = false
    private var trackingAreaRef: NSTrackingArea?

    var onClick: (() -> Void)?

    init(frame: NSRect, symbolName: String, iconSize: CGFloat) {
        self.size = frame.width
        self.iconSize = iconSize
        self.symbolName = symbolName
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        contentLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.position = CGPoint(x: size / 2.0, y: size / 2.0)
        contentLayer.masksToBounds = false
        layer?.addSublayer(contentLayer)

        bgLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        bgLayer.position = CGPoint(x: size / 2.0, y: size / 2.0)
        bgLayer.cornerRadius = size / 2.0
        bgLayer.borderWidth = 0.5
        bgLayer.borderColor = NSColor.clear.cgColor
        bgLayer.backgroundColor = NSColor.clear.cgColor
        contentLayer.addSublayer(bgLayer)

        iconLayer.bounds = CGRect(x: 0, y: 0, width: iconSize + 6, height: iconSize + 6)
        iconLayer.position = CGPoint(x: size / 2.0, y: size / 2.0)
        iconLayer.contentsGravity = .resizeAspect
        contentLayer.addSublayer(iconLayer)

        updateSymbol(symbolName)
        updateAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSymbol(symbolName)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSymbol(symbolName)
    }

    func updateSymbol(_ name: String) {
        self.symbolName = name
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let sz = NSSize(width: iconSize + 6, height: iconSize + 6)
        iconLayer.contents = rasterizeRetinaSymbol(name, pointSize: iconSize, weight: .semibold, color: .white, canvasSize: sz, scale: scale)
        iconLayer.contentsScale = scale
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
        animateScale(1.06)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateAppearance()
        animateScale(1.0)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        animateScale(0.86)
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        isPressed = false
        animateScale(isHovered ? 1.06 : 1.0)
        if bounds.contains(pt) {
            onClick?()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        bgLayer.backgroundColor = NSColor.white.withAlphaComponent(isHovered ? 0.15 : 0.0).cgColor
        bgLayer.borderColor = NSColor.white.withAlphaComponent(isHovered ? 0.20 : 0.0).cgColor
        iconLayer.opacity = isHovered ? 1.0 : 0.88
        CATransaction.commit()
    }

    private func animateScale(_ target: CGFloat) {
        let toTransform = CATransform3DMakeScale(target, target, 1.0)
        if AppPerformance.isUltraLightMode {
            let anim = CABasicAnimation(keyPath: "transform")
            anim.duration = 0.12
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            anim.fromValue = contentLayer.presentation()?.transform ?? contentLayer.transform
            anim.toValue = toTransform
            contentLayer.transform = toTransform
            contentLayer.add(anim, forKey: "btnScale")
        } else {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1.0
            spring.stiffness = 420
            spring.damping = 24
            spring.fromValue = contentLayer.presentation()?.transform ?? contentLayer.transform
            spring.toValue = toTransform
            spring.duration = spring.settlingDuration
            contentLayer.transform = toTransform
            contentLayer.add(spring, forKey: "btnScale")
        }
    }
}

// MARK: - Circular Glass Icon Button (Settings / Close)

@MainActor
private final class GlassIconCircleButton: NSView {
    private let bg = NSVisualEffectView()
    private let iconLayer = CALayer()
    private let badgeLayer = CALayer()
    private let symbolName: String
    private let pointSize: CGFloat
    private let weight: NSFont.Weight
    private var backingScale: CGFloat = 2.0
    private var trackingAreaRef: NSTrackingArea?
    var onClick: (() -> Void)?

    init(frame: NSRect, symbolName: String, pointSize: CGFloat, weight: NSFont.Weight) {
        self.symbolName = symbolName
        self.pointSize = pointSize
        self.weight = weight
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        bg.frame = bounds
        bg.material = .hudWindow
        bg.blendingMode = .withinWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = bounds.width / 2.0
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        addSubview(bg)

        iconLayer.frame = bounds
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
        updateSymbolTexture()

        badgeLayer.frame = CGRect(x: bounds.width - 6, y: bounds.height - 6, width: 7, height: 7)
        badgeLayer.cornerRadius = 3.5
        badgeLayer.backgroundColor = NSColor.systemOrange.cgColor
        badgeLayer.isHidden = true
        layer?.addSublayer(badgeLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSymbolTexture()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSymbolTexture()
    }

    private func updateSymbolTexture() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        backingScale = scale
        iconLayer.contents = rasterizeRetinaSymbol(
            symbolName,
            pointSize: pointSize,
            weight: weight,
            color: NSColor.white.withAlphaComponent(0.88),
            canvasSize: bounds.size,
            scale: scale
        )
        iconLayer.contentsScale = scale
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func setShowBadge(_ show: Bool) {
        badgeLayer.isHidden = !show
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        iconLayer.opacity = 0.55
    }

    override func mouseUp(with event: NSEvent) {
        iconLayer.opacity = 1.0
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onClick?()
        }
    }
}

@MainActor
private final class ClickableAreaView: NSView {
    private var trackingAreaRef: NSTrackingArea?
    var onClick: (() -> Void)?
    var isClickEnabled: (() -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        if isClickEnabled?() ?? true {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt), (isClickEnabled?() ?? true) {
            onClick?()
        }
    }
}

// MARK: - Native AppKit Software Update Modal Overlay

@MainActor
private final class HUDUpdateModalOverlay: NSView {
    private let cardEffect = NSVisualEffectView()
    private let cardTintLayer = CALayer()
    private let cardBorderLayer = CAShapeLayer()
    private let versionPillLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let notesScroll = NSScrollView()
    private let notesTextView = NSTextView()
    private let progressContainer = NSView()
    private let progressTitle = NSTextField(labelWithString: "Downloading update")
    private let progressPercent = NSTextField(labelWithString: "0%")
    private let progressTrack = CALayer()
    private let progressFill = CAGradientLayer()
    private let installingSpinner = NSProgressIndicator()
    private let installingLabel = NSTextField(labelWithString: "Restarting app in a moment...")
    private let laterButton = NSButton(title: "Later", target: nil, action: nil)
    private let updateNowButton = NSButton(title: "Update Now", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous

        let cardW: CGFloat = 410
        let cardH: CGFloat = 200
        let cardFrame = NSRect(x: (bounds.width - cardW) / 2.0, y: (bounds.height - cardH) / 2.0, width: cardW, height: cardH)

        cardEffect.frame = cardFrame
        cardEffect.material = .hudWindow
        cardEffect.blendingMode = .withinWindow
        cardEffect.state = .active
        cardEffect.wantsLayer = true
        cardEffect.layer?.cornerRadius = 16
        cardEffect.layer?.cornerCurve = .continuous
        cardEffect.layer?.masksToBounds = true

        cardTintLayer.frame = cardEffect.bounds
        cardTintLayer.backgroundColor = NSColor(white: 0.10, alpha: 0.78).cgColor
        cardEffect.layer?.addSublayer(cardTintLayer)

        cardBorderLayer.frame = cardEffect.bounds
        cardBorderLayer.path = CGPath(roundedRect: cardEffect.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 15.5, cornerHeight: 15.5, transform: nil)
        cardBorderLayer.fillColor = NSColor.clear.cgColor
        cardBorderLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        cardBorderLayer.lineWidth = 0.75
        cardEffect.layer?.addSublayer(cardBorderLayer)
        addSubview(cardEffect)

        // Header: App Icon
        let iconView = NSImageView(frame: NSRect(x: 16, y: cardH - 16 - 44, width: 44, height: 44))
        iconView.image = NSApp.applicationIconImage
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 10
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        cardEffect.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "Software Update")
        titleLabel.frame = NSRect(x: 72, y: cardH - 36, width: 130, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        titleLabel.textColor = .white
        cardEffect.addSubview(titleLabel)

        versionPillLabel.frame = NSRect(x: 196, y: cardH - 36, width: 64, height: 17)
        versionPillLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        versionPillLabel.textColor = NSColor(calibratedRed: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
        versionPillLabel.alignment = .center
        versionPillLabel.wantsLayer = true
        versionPillLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.5, blue: 1.0, alpha: 0.22).cgColor
        versionPillLabel.layer?.cornerRadius = 8.5
        cardEffect.addSubview(versionPillLabel)

        subtitleLabel.frame = NSRect(x: 72, y: cardH - 56, width: 295, height: 15)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        cardEffect.addSubview(subtitleLabel)

        let closeBtn = NSButton(frame: NSRect(x: cardW - 36, y: cardH - 36, width: 20, height: 20))
        closeBtn.isBordered = false
        closeBtn.title = "✕"
        closeBtn.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        closeBtn.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        closeBtn.target = self
        closeBtn.action = #selector(cancelTapped)
        cardEffect.addSubview(closeBtn)

        // Notes Box
        notesScroll.frame = NSRect(x: 16, y: 54, width: cardW - 32, height: 74)
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = true
        notesScroll.backgroundColor = NSColor.black.withAlphaComponent(0.28)
        notesScroll.wantsLayer = true
        notesScroll.layer?.cornerRadius = 9
        notesScroll.layer?.borderWidth = 0.5
        notesScroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        notesTextView.isEditable = false
        notesTextView.drawsBackground = false
        notesTextView.font = NSFont.systemFont(ofSize: 11)
        notesTextView.textColor = NSColor.white.withAlphaComponent(0.88)
        notesTextView.textContainerInset = NSSize(width: 6, height: 6)
        notesScroll.documentView = notesTextView
        cardEffect.addSubview(notesScroll)

        // Progress Area
        progressContainer.frame = NSRect(x: 16, y: 54, width: cardW - 32, height: 54)
        progressContainer.wantsLayer = true
        progressContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        progressContainer.layer?.cornerRadius = 9
        progressTitle.frame = NSRect(x: 12, y: 28, width: 200, height: 16)
        progressTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        progressTitle.textColor = NSColor.white.withAlphaComponent(0.8)
        progressPercent.frame = NSRect(x: cardW - 104, y: 28, width: 60, height: 16)
        progressPercent.alignment = .right
        progressPercent.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        progressPercent.textColor = .white
        progressTrack.frame = CGRect(x: 12, y: 12, width: cardW - 56, height: 6)
        progressTrack.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        progressTrack.cornerRadius = 3
        progressFill.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
        progressFill.cornerRadius = 3
        progressFill.colors = [
            NSColor(calibratedRed: 0.1, green: 0.6, blue: 1.0, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.35, green: 0.85, blue: 1.0, alpha: 1.0).cgColor
        ]
        progressFill.startPoint = CGPoint(x: 0, y: 0.5)
        progressFill.endPoint = CGPoint(x: 1, y: 0.5)
        progressTrack.addSublayer(progressFill)
        progressContainer.layer?.addSublayer(progressTrack)
        progressContainer.addSubview(progressTitle)
        progressContainer.addSubview(progressPercent)
        progressContainer.isHidden = true
        cardEffect.addSubview(progressContainer)

        // Installing
        installingSpinner.style = .spinning
        installingSpinner.controlSize = .small
        installingSpinner.frame = NSRect(x: 115, y: 74, width: 16, height: 16)
        installingSpinner.isHidden = true
        installingLabel.frame = NSRect(x: 138, y: 73, width: 220, height: 18)
        installingLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        installingLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        installingLabel.isHidden = true
        cardEffect.addSubview(installingSpinner)
        cardEffect.addSubview(installingLabel)

        // Footer Buttons
        laterButton.frame = NSRect(x: 16, y: 14, width: 78, height: 28)
        laterButton.bezelStyle = .rounded
        laterButton.target = self
        laterButton.action = #selector(cancelTapped)
        cardEffect.addSubview(laterButton)

        updateNowButton.frame = NSRect(x: cardW - 122, y: 14, width: 106, height: 28)
        updateNowButton.bezelStyle = .rounded
        updateNowButton.keyEquivalent = "\r"
        updateNowButton.target = self
        updateNowButton.action = #selector(updateNowTapped)
        cardEffect.addSubview(updateNowButton)
    }

    func refreshState() {
        let eng = LyricsCoreEngine.shared
        switch eng.updateState {
        case .updateAvailable(let ver, let notes, _):
            versionPillLabel.isHidden = false
            versionPillLabel.stringValue = "v\(ver)"
            subtitleLabel.stringValue = "Lyrics Menu Bar \(ver) is available (Current: v\(eng.currentVersion))"
            notesTextView.string = notes
            notesScroll.isHidden = false
            progressContainer.isHidden = true
            installingSpinner.isHidden = true
            installingSpinner.stopAnimation(nil)
            installingLabel.isHidden = true
            laterButton.title = "Later"
            updateNowButton.isHidden = false

        case .downloading(let progress):
            notesScroll.isHidden = true
            progressContainer.isHidden = false
            installingSpinner.isHidden = true
            installingLabel.isHidden = true
            subtitleLabel.stringValue = "Downloading package from GitHub Releases..."
            progressPercent.stringValue = "\(Int(progress * 100))%"
            let maxW = progressTrack.bounds.width
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progressFill.frame = CGRect(x: 0, y: 0, width: max(6.0, maxW * CGFloat(progress)), height: 6)
            CATransaction.commit()
            laterButton.title = "Cancel"
            updateNowButton.isHidden = true

        case .installing:
            notesScroll.isHidden = true
            progressContainer.isHidden = true
            installingSpinner.isHidden = false
            installingSpinner.startAnimation(nil)
            installingLabel.isHidden = false
            subtitleLabel.stringValue = "Verifying package and relaunching application..."
            laterButton.title = "Dismiss"
            updateNowButton.isHidden = true

        case .failed(let err):
            notesScroll.isHidden = false
            notesTextView.string = err
            progressContainer.isHidden = true
            installingSpinner.isHidden = true
            installingLabel.isHidden = true
            subtitleLabel.stringValue = "Update failed"
            laterButton.title = "Close"
            updateNowButton.isHidden = true

        default:
            break
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if !cardEffect.frame.contains(pt) {
            if case .downloading = LyricsCoreEngine.shared.updateState { return }
            LyricsCoreEngine.shared.cancelUpdateDownload()
        }
    }

    @objc private func cancelTapped() {
        LyricsCoreEngine.shared.cancelUpdateDownload()
    }

    @objc private func updateNowTapped() {
        LyricsCoreEngine.shared.startDownloadAndInstall()
    }
}

// MARK: - Main Zero-SwiftUI HUD Content View (480 x 240)

@MainActor
final class HUDContentView: NSView {
    let lyricsView = HUDLyricsView(frame: NSRect(x: 176, y: 16, width: 286, height: 208))

    private let artButton = ClickableAreaView(frame: NSRect(x: 29, y: 102, width: 120, height: 120))
    private let artContentLayer = CALayer()
    private let artImageLayer = CALayer()
    private let artPlaceholderLayer = CALayer()
    private let artSymbolLayer = CALayer()

    private let trackInfoButton = ClickableAreaView(frame: NSRect(x: 18, y: 60, width: 142, height: 34))
    private let titleLabel = NSTextField(labelWithString: "No Music Playing")
    private let artistLabel = NSTextField(labelWithString: "Open Spotify or Apple Music")

    private let prevBtn = TactileCircleButton(frame: NSRect(x: 34, y: 18, width: 32, height: 32), symbolName: "backward.fill", iconSize: 15)
    private let playPauseBtn = TactileCircleButton(frame: NSRect(x: 70, y: 15, width: 38, height: 38), symbolName: "play.fill", iconSize: 20)
    private let nextBtn = TactileCircleButton(frame: NSRect(x: 112, y: 18, width: 32, height: 32), symbolName: "forward.fill", iconSize: 15)

    private let settingsBtn = GlassIconCircleButton(frame: NSRect(x: 406, y: 200, width: 26, height: 26), symbolName: "ellipsis", pointSize: 12, weight: .bold)
    private let closeBtn = GlassIconCircleButton(frame: NSRect(x: 440, y: 200, width: 26, height: 26), symbolName: "chevron.up", pointSize: 10, weight: .bold)

    private var updateModal: HUDUpdateModalOverlay?
    private var lastArtworkRevision = -1
    private var lastIsPlaying = false
    private var hasInitializedPlayState = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // 1. Left Column: Album Art (120 x 120)
        artButton.wantsLayer = true
        artButton.layer?.masksToBounds = false

        artContentLayer.bounds = artButton.bounds
        artContentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        artContentLayer.position = CGPoint(x: artButton.bounds.width / 2.0, y: artButton.bounds.height / 2.0)
        artContentLayer.cornerRadius = 14
        artContentLayer.cornerCurve = .continuous
        artContentLayer.masksToBounds = true
        artContentLayer.borderWidth = 0.5
        artContentLayer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        artButton.layer?.addSublayer(artContentLayer)

        let grad = CAGradientLayer()
        grad.frame = artButton.bounds
        grad.colors = [NSColor.white.withAlphaComponent(0.08).cgColor, NSColor.white.withAlphaComponent(0.03).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 1)
        grad.endPoint = CGPoint(x: 1, y: 0)
        artPlaceholderLayer.frame = artButton.bounds
        artPlaceholderLayer.addSublayer(grad)

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        artSymbolLayer.frame = artButton.bounds
        artSymbolLayer.contentsGravity = .resizeAspect
        artSymbolLayer.contentsScale = scale
        artSymbolLayer.contents = rasterizeRetinaSymbol(
            "play.fill",
            pointSize: 36,
            weight: .regular,
            color: NSColor.white.withAlphaComponent(0.45),
            canvasSize: artButton.bounds.size,
            scale: scale
        )
        artPlaceholderLayer.addSublayer(artSymbolLayer)
        artContentLayer.addSublayer(artPlaceholderLayer)

        artImageLayer.frame = artButton.bounds
        artImageLayer.contentsGravity = .resizeAspectFill
        artImageLayer.contentsScale = scale
        artImageLayer.isHidden = true
        artContentLayer.addSublayer(artImageLayer)
        addSubview(artButton)

        // Clickable Track Info
        titleLabel.frame = NSRect(x: 0, y: 16, width: 142, height: 18)
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        trackInfoButton.addSubview(titleLabel)

        artistLabel.frame = NSRect(x: 0, y: 0, width: 142, height: 15)
        artistLabel.alignment = .center
        artistLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        artistLabel.textColor = NSColor.white.withAlphaComponent(0.70)
        artistLabel.lineBreakMode = .byTruncatingTail
        trackInfoButton.addSubview(artistLabel)
        addSubview(trackInfoButton)

        // Click handlers on art & track info
        let hasTrackCheck: () -> Bool = { LyricsCoreEngine.shared.currentTrack != nil }
        artButton.isClickEnabled = hasTrackCheck
        artButton.onClick = { [weak self] in self?.handleActivateMusicApp() }
        trackInfoButton.isClickEnabled = hasTrackCheck
        trackInfoButton.onClick = { [weak self] in self?.handleActivateMusicApp() }

        // Playback Controls
        prevBtn.onClick = { MusicIPCBridge.shared.previousTrack() }
        playPauseBtn.onClick = { MusicIPCBridge.shared.playPause() }
        nextBtn.onClick = { MusicIPCBridge.shared.nextTrack() }
        addSubview(prevBtn)
        addSubview(playPauseBtn)
        addSubview(nextBtn)

        // 2. Right Column: Virtualized 60 FPS Lyrics Stream
        lyricsView.onSeek = { idx, line in
            let engine = LyricsCoreEngine.shared
            let seekTime: Double
            if line.time > 0 {
                seekTime = line.time
            } else {
                let dur = engine.currentTrack?.duration ?? 180.0
                seekTime = (Double(idx) / Double(max(1, engine.lyrics.count))) * dur
            }
            MusicIPCBridge.shared.seek(to: seekTime)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        addSubview(lyricsView)

        // 3. Top Right Buttons
        settingsBtn.onClick = { [weak self] in
            guard let self = self else { return }
            SettingsMenuController.shared.showMenu(anchoredTo: self.settingsBtn)
        }
        closeBtn.onClick = {
            NotificationCenter.default.post(name: Notification.Name("ClosePopover"), object: nil)
        }
        addSubview(settingsBtn)
        addSubview(closeBtn)

        // Observe RustCore notifications
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleTrackChanged), name: LyricsCoreEngine.trackDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleLyricsChanged), name: LyricsCoreEngine.lyricsDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleArtworkChanged), name: LyricsCoreEngine.artworkDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handlePlayStateChanged), name: LyricsCoreEngine.playStateDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleUpdateStateChanged), name: LyricsCoreEngine.updateStateDidChangeNotification, object: nil)

        refreshAll()
        refreshUpdateModal()
    }

    @objc private func handleTrackChanged() { refreshAll() }
    @objc private func handleLyricsChanged() { lyricsView.invalidateLyricsAndScrollReset() }
    @objc private func handleArtworkChanged() { refreshArtwork() }
    @objc private func handlePlayStateChanged() { refreshPlayState() }
    @objc private func handleUpdateStateChanged() { refreshUpdateModal() }

    @objc private func handleActivateMusicApp() {
        MusicIPCBridge.shared.activateMusicApp()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func refreshAll() {
        let eng = LyricsCoreEngine.shared
        if let track = eng.currentTrack {
            titleLabel.stringValue = track.name
            artistLabel.stringValue = track.artist
            let appLabel = eng.activeSource == .appleMusic ? "Apple Music" : "Spotify"
            artButton.toolTip = "Click to open in \(appLabel)"
            trackInfoButton.toolTip = "Click to open in \(appLabel)"
        } else {
            titleLabel.stringValue = "No Music Playing"
            artistLabel.stringValue = "Open Spotify or Apple Music"
            artButton.toolTip = nil
            trackInfoButton.toolTip = nil
        }
        refreshArtwork()
        refreshPlayState()
        lyricsView.invalidateLyricsAndScrollReset()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshBackingScaleTextures()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshBackingScaleTextures()
    }

    private func refreshBackingScaleTextures() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        artSymbolLayer.contentsScale = scale
        artImageLayer.contentsScale = scale
        artSymbolLayer.contents = rasterizeRetinaSymbol(
            "play.fill",
            pointSize: 36,
            weight: .regular,
            color: NSColor.white.withAlphaComponent(0.45),
            canvasSize: artButton.bounds.size,
            scale: scale
        )
    }

    private func refreshArtwork() {
        let eng = LyricsCoreEngine.shared
        guard lastArtworkRevision != eng.artworkRevision else { return }
        lastArtworkRevision = eng.artworkRevision

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let img = eng.artworkImage {
            artImageLayer.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? img
            artImageLayer.contentsScale = scale
            artImageLayer.isHidden = false
            artPlaceholderLayer.isHidden = true
        } else {
            artImageLayer.contents = nil
            artImageLayer.isHidden = true
            artPlaceholderLayer.isHidden = false
        }
        CATransaction.commit()
    }

    private func refreshPlayState() {
        let playing = LyricsCoreEngine.shared.isPlaying
        let animate = hasInitializedPlayState
        guard !hasInitializedPlayState || playing != lastIsPlaying else { return }
        hasInitializedPlayState = true
        lastIsPlaying = playing
        playPauseBtn.updateSymbol(playing ? "pause.fill" : "play.fill")

        let targetScale: CGFloat = playing ? 1.0 : 0.92
        let toTransform = CATransform3DMakeScale(targetScale, targetScale, 1.0)
        if !animate {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artContentLayer.transform = toTransform
            CATransaction.commit()
            return
        }
        if AppPerformance.isUltraLightMode {
            let anim = CABasicAnimation(keyPath: "transform")
            anim.duration = 0.22
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            anim.fromValue = artContentLayer.presentation()?.transform ?? artContentLayer.transform
            anim.toValue = toTransform
            artContentLayer.transform = toTransform
            artContentLayer.add(anim, forKey: "artScale")
        } else {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1.0
            spring.stiffness = 220
            spring.damping = 24
            spring.fromValue = artContentLayer.presentation()?.transform ?? artContentLayer.transform
            spring.toValue = toTransform
            spring.duration = spring.settlingDuration
            artContentLayer.transform = toTransform
            artContentLayer.add(spring, forKey: "artScale")
        }
    }

    private func refreshUpdateModal() {
        let eng = LyricsCoreEngine.shared
        settingsBtn.setShowBadge(eng.hasUpdate)

        if eng.showUpdateModal {
            if updateModal == nil {
                let overlay = HUDUpdateModalOverlay(frame: bounds)
                addSubview(overlay)
                updateModal = overlay
            }
            updateModal?.refreshState()
        } else {
            updateModal?.removeFromSuperview()
            updateModal = nil
        }
    }
}
