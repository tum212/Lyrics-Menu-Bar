import AppKit
import QuartzCore

// MARK: - Native GPU Backdrop Glass
final class HUDGlassView: NSView {
    
    // Core Engine: Native macOS Popover glass that naturally adapts to light & dark backgrounds
    private let visualEffect = NSVisualEffectView()
    
    // Optical Rim & Specular Layers
    private let rimGradientLayer = CAGradientLayer()
    private let rimMaskLayer = CAShapeLayer()
    private let topRefractionSheen = CAGradientLayer()
    private let innerSoftGlow = CAShapeLayer()
    
    private let cornerRadiusValue: CGFloat = 26.0
    
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
        
        // 1. Native macOS Popover Glass (Zero fake tint - 100% optical clarity)
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.cornerRadius = cornerRadiusValue
        visualEffect.layer?.cornerCurve = .continuous
        self.addSubview(visualEffect)
        
        // 2. Hardware CABackdropLayer for Vibrant Saturation boost
        if let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            let backdrop = cls.init()
            backdrop.masksToBounds = true
            backdrop.cornerRadius = cornerRadiusValue
            backdrop.cornerCurve = .continuous
            backdrop.setValue(true, forKey: "windowServerAware")
            backdrop.setValue(true, forKey: "enabled")
            
            if let filterClass = NSClassFromString("CAFilter") as? NSObject.Type {
                if let sat = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "colorSaturate")?.takeUnretainedValue() as? NSObject {
                    sat.setValue(1.6, forKey: "inputAmount")
                    backdrop.filters = [sat]
                }
            }
            self.layer?.addSublayer(backdrop)
        }
        
        // 3. Top Refraction Sheen (Light bending across the top curve)
        topRefractionSheen.masksToBounds = true
        topRefractionSheen.cornerRadius = cornerRadiusValue
        topRefractionSheen.cornerCurve = .continuous
        topRefractionSheen.startPoint = CGPoint(x: 0.5, y: 0.0)
        topRefractionSheen.endPoint = CGPoint(x: 0.5, y: 0.28)
        self.layer?.addSublayer(topRefractionSheen)
        
        // 4. Soft Inner Glow (2.0px diffuse refraction hugging the perimeter)
        innerSoftGlow.fillColor = NSColor.clear.cgColor
        innerSoftGlow.lineWidth = 2.5
        innerSoftGlow.lineCap = .round
        self.layer?.addSublayer(innerSoftGlow)
        
        // 5. Specular Optical Rim Gradient (1.5px crisp highlight reflection)
        rimMaskLayer.fillColor = NSColor.clear.cgColor
        rimMaskLayer.strokeColor = NSColor.white.cgColor
        rimMaskLayer.lineWidth = 1.5
        rimMaskLayer.lineCap = .round
        
        rimGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        rimGradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        rimGradientLayer.mask = rimMaskLayer
        self.layer?.addSublayer(rimGradientLayer)
        
        self.addObserver(self, forKeyPath: "effectiveAppearance", options: .new, context: nil)
        updateColorsForAppearance()
    }
    
    private func updateColorsForAppearance() {
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = self.effectiveAppearance.name == .darkAqua || self.effectiveAppearance.name == .vibrantDark
            
            // Top Refraction Sheen: light catching the upper glass curve
            topRefractionSheen.colors = [
                isDark ? NSColor.white.withAlphaComponent(0.18).cgColor : NSColor.white.withAlphaComponent(0.40).cgColor,
                NSColor.clear.cgColor
            ]
            
            // Soft Inner Glow: ambient light bleeding inside the squircle edge
            innerSoftGlow.strokeColor = isDark
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.white.withAlphaComponent(0.35).cgColor
            
            // Specular Rim: high-visibility optical refraction highlight
            if isDark {
                rimGradientLayer.colors = [
                    NSColor.white.withAlphaComponent(0.85).cgColor, // Crisp bright specular reflection at top-left
                    NSColor.white.withAlphaComponent(0.45).cgColor,
                    NSColor.white.withAlphaComponent(0.15).cgColor,
                    NSColor.white.withAlphaComponent(0.35).cgColor  // Bottom-right rim reflection
                ]
            } else {
                rimGradientLayer.colors = [
                    NSColor.white.withAlphaComponent(0.95).cgColor,
                    NSColor.white.withAlphaComponent(0.60).cgColor,
                    NSColor.white.withAlphaComponent(0.25).cgColor,
                    NSColor.white.withAlphaComponent(0.50).cgColor
                ]
            }
            rimGradientLayer.locations = [0.0, 0.30, 0.70, 1.0]
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            DispatchQueue.main.async { [weak self] in
                self?.updateColorsForAppearance()
            }
        }
    }
    
    deinit {
        self.removeObserver(self, forKeyPath: "effectiveAppearance")
    }
    
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        visualEffect.frame = bounds
        topRefractionSheen.frame = bounds
        rimGradientLayer.frame = bounds
        
        // 1.5px inset path for the crisp specular rim
        let strokeBounds = bounds.insetBy(dx: 0.75, dy: 0.75)
        rimMaskLayer.frame = bounds
        rimMaskLayer.path = CGPath(roundedRect: strokeBounds, cornerWidth: cornerRadiusValue - 0.75, cornerHeight: cornerRadiusValue - 0.75, transform: nil)
        
        // 2.0px inset path for the soft inner ambient glow
        let innerBounds = bounds.insetBy(dx: 1.5, dy: 1.5)
        innerSoftGlow.frame = bounds
        innerSoftGlow.path = CGPath(roundedRect: innerBounds, cornerWidth: cornerRadiusValue - 1.5, cornerHeight: cornerRadiusValue - 1.5, transform: nil)
        
        CATransaction.commit()
    }
}
