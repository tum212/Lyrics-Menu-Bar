import AppKit
import QuartzCore

// MARK: - Native GPU Backdrop Glass (Adaptive Standard / Ultra-Light)
final class HUDGlassView: NSView {
    
    // Core Engine: Native macOS Popover glass that naturally adapts to light & dark backgrounds
    private let visualEffect = NSVisualEffectView()
    
    // Optional Standard-mode GPU Backdrop & Specular Layers
    private var backdropLayer: CALayer?
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
        
        self.addObserver(self, forKeyPath: "effectiveAppearance", options: .new, context: nil)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePerformanceModeChanged),
            name: Notification.Name("UltraLightModeChanged"),
            object: nil
        )
        
        updateForPerformanceMode()
    }
    
    @objc private func handlePerformanceModeChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateForPerformanceMode()
        }
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
            visualEffect.material = .popover
            self.layer?.borderWidth = 0.0
            self.layer?.borderColor = nil
            
            if backdropLayer == nil, let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type {
                let backdrop = cls.init()
                backdrop.masksToBounds = true
                backdrop.cornerRadius = cornerRadiusValue
                backdrop.cornerCurve = .continuous
                backdrop.setValue(true, forKey: "windowServerAware")
                backdrop.setValue(true, forKey: "enabled")
                
                if let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
                   let sat = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "colorSaturate")?.takeUnretainedValue() as? NSObject {
                    sat.setValue(1.6, forKey: "inputAmount")
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
            innerSoftGlow.isHidden = false
            rimGradientLayer.isHidden = false
            updateColorsForAppearance()
        }
        
        CATransaction.commit()
        needsLayout = true
    }
    
    private func updateColorsForAppearance() {
        guard !AppPerformance.isUltraLightMode else { return }
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = self.effectiveAppearance.name == .darkAqua || self.effectiveAppearance.name == .vibrantDark
            
            topRefractionSheen.colors = [
                isDark ? NSColor.white.withAlphaComponent(0.18).cgColor : NSColor.white.withAlphaComponent(0.40).cgColor,
                NSColor.clear.cgColor
            ]
            
            innerSoftGlow.strokeColor = isDark
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.white.withAlphaComponent(0.35).cgColor
            
            if isDark {
                rimGradientLayer.colors = [
                    NSColor.white.withAlphaComponent(0.85).cgColor,
                    NSColor.white.withAlphaComponent(0.45).cgColor,
                    NSColor.white.withAlphaComponent(0.15).cgColor,
                    NSColor.white.withAlphaComponent(0.35).cgColor
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
        NotificationCenter.default.removeObserver(self)
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
