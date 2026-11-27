import AppKit
import QuartzCore

// MARK: - Native GPU Backdrop Glass (Adaptive Standard / Ultra-Light)
@MainActor
final class HUDGlassView: NSView {

    // Core Engine: Native macOS Popover glass
    private let visualEffect = NSVisualEffectView()

    // Optional Standard-mode GPU Backdrop & Specular Layers
    private var backdropLayer: CALayer?
    private let rimGradientLayer = CAGradientLayer()
    private let rimMaskLayer = CAShapeLayer()
    private let topRefractionSheen = CAGradientLayer()
    private let innerSoftGlow = CAShapeLayer()

    private let cornerRadiusValue: CGFloat = 26.0
    private var backingScale: CGFloat = 2.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        self.wantsLayer = true
        self.layer?.masksToBounds = true
        self.layer?.cornerRadius = cornerRadiusValue
        self.layer?.cornerCurve = .continuous

        // 1. Native macOS Glass View
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.cornerRadius = cornerRadiusValue
        visualEffect.layer?.cornerCurve = .continuous
        self.addSubview(visualEffect)

        // Setup optical layers once (hidden in Ultra-Light mode)
        topRefractionSheen.masksToBounds = true
        topRefractionSheen.cornerRadius = cornerRadiusValue
        topRefractionSheen.cornerCurve = .continuous
        topRefractionSheen.startPoint = CGPoint(x: 0.5, y: 0.0)
        topRefractionSheen.endPoint = CGPoint(x: 0.5, y: 0.28)
        self.layer?.addSublayer(topRefractionSheen)

        innerSoftGlow.fillColor = NSColor.clear.cgColor
        innerSoftGlow.lineWidth = 2.5
        innerSoftGlow.lineCap = .round
        self.layer?.addSublayer(innerSoftGlow)

        rimMaskLayer.fillColor = NSColor.clear.cgColor
        rimMaskLayer.strokeColor = NSColor.white.cgColor
        rimMaskLayer.lineWidth = 1.5
        rimMaskLayer.lineCap = .round

        rimGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        rimGradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        rimGradientLayer.mask = rimMaskLayer
        self.layer?.addSublayer(rimGradientLayer)

        applyBackingScale()
        updateForPerformanceMode()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackingScale()
        updateColorsForAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorsForAppearance()
    }

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        backingScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        backdropLayer?.contentsScale = scale
        topRefractionSheen.contentsScale = scale
        innerSoftGlow.contentsScale = scale
        rimMaskLayer.contentsScale = scale
        rimGradientLayer.contentsScale = scale
        CATransaction.commit()
    }

    public func updateForPerformanceMode() {
        let isUltraLight = AppPerformance.isUltraLightMode
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isUltraLight {
            // Single-pass native AppKit vibrancy: zero dual-backdrop GPU overhead on Intel iGPUs
            visualEffect.material = .hudWindow
            backdropLayer?.removeFromSuperlayer()
            backdropLayer = nil
            topRefractionSheen.isHidden = true
            innerSoftGlow.isHidden = true
            rimGradientLayer.isHidden = true
            self.layer?.borderWidth = 0.75
            self.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        } else {
            visualEffect.material = .hudWindow
            let specularOn = UserDefaults.standard.object(forKey: AppSettingKey.specularEdgeEnabled) == nil
                ? !AppPerformance.defaultUltraLightMode
                : UserDefaults.standard.bool(forKey: AppSettingKey.specularEdgeEnabled)
            self.layer?.borderWidth = 0.0
            self.layer?.borderColor = nil

            if backdropLayer == nil, let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type {
                let backdrop = cls.init()
                backdrop.masksToBounds = true
                backdrop.cornerRadius = cornerRadiusValue
                backdrop.cornerCurve = .continuous
                backdrop.contentsScale = backingScale
                backdrop.setValue(true, forKey: "windowServerAware")
                backdrop.setValue(true, forKey: "enabled")

                if let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
                   let sat = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "colorSaturate")?.takeUnretainedValue() as? NSObject {
                    sat.setValue(1.5, forKey: "inputAmount")
                    backdrop.filters = [sat]
                }
                if let veLayer = visualEffect.layer {
                    self.layer?.insertSublayer(backdrop, above: veLayer)
                } else {
                    self.layer?.insertSublayer(backdrop, at: 0)
                }
                backdrop.frame = bounds
                backdropLayer = backdrop
            }

            topRefractionSheen.isHidden = false
            innerSoftGlow.isHidden = !specularOn
            rimGradientLayer.isHidden = !specularOn
            updateColorsForAppearance()
        }

        CATransaction.commit()
        needsLayout = true
        layout()
    }

    private func updateColorsForAppearance() {
        guard !AppPerformance.isUltraLightMode else { return }
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            topRefractionSheen.colors = [
                isDark ? NSColor.white.withAlphaComponent(0.18).cgColor : NSColor.white.withAlphaComponent(0.32).cgColor,
                NSColor.clear.cgColor
            ]

            innerSoftGlow.strokeColor = isDark
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.white.withAlphaComponent(0.28).cgColor

            if isDark {
                rimGradientLayer.colors = [
                    NSColor.white.withAlphaComponent(0.82).cgColor,
                    NSColor.white.withAlphaComponent(0.42).cgColor,
                    NSColor.white.withAlphaComponent(0.15).cgColor,
                    NSColor.white.withAlphaComponent(0.34).cgColor
                ]
            } else {
                rimGradientLayer.colors = [
                    NSColor.white.withAlphaComponent(0.90).cgColor,
                    NSColor.white.withAlphaComponent(0.55).cgColor,
                    NSColor.white.withAlphaComponent(0.22).cgColor,
                    NSColor.white.withAlphaComponent(0.45).cgColor
                ]
            }
            rimGradientLayer.locations = [0.0, 0.30, 0.70, 1.0]
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        visualEffect.frame = bounds
        backdropLayer?.frame = bounds
        if AppPerformance.isUltraLightMode {
            CATransaction.commit()
            return
        }
        topRefractionSheen.frame = bounds
        rimGradientLayer.frame = bounds

        let strokeBounds = bounds.insetBy(dx: 0.75, dy: 0.75)
        rimMaskLayer.frame = bounds
        rimMaskLayer.path = CGPath(roundedRect: strokeBounds, cornerWidth: cornerRadiusValue - 0.75, cornerHeight: cornerRadiusValue - 0.75, transform: nil)

        let innerBounds = bounds.insetBy(dx: 1.5, dy: 1.5)
        innerSoftGlow.frame = bounds
        innerSoftGlow.path = CGPath(roundedRect: innerBounds, cornerWidth: cornerRadiusValue - 1.5, cornerHeight: cornerRadiusValue - 1.5, transform: nil)

        CATransaction.commit()
    }
}
