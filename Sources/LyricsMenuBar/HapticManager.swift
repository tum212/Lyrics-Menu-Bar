import AppKit
import CoreHaptics
import IOKit

final class HapticManager: @unchecked Sendable {
    static let shared = HapticManager()
    
    private let queue = DispatchQueue(label: "com.lyricsmenubar.haptics", qos: .userInteractive)
    
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    
    // Anti-fatigue tracking
    private var lastTransientTime: TimeInterval = 0
    private var lastContinuousAmplitude: Float = 0
    private var lastDeepBass: Float = 0
    private var lastStandardBass: Float = 0
    private var continuousDuration: TimeInterval = 0
    
    // State
    private var isPlaying = false
    
    var isSupported: Bool {
        return CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }
    
    // MultitouchSupport Private API References
    private var mtActuator: UnsafeMutableRawPointer? = nil
    private typealias MTActuatorCreateFromDeviceIDType = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias MTActuatorOpenType = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias MTActuatorActuateType = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float32, Float32) -> Int32
    private typealias MTActuatorCloseType = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private var mtActuateFn: MTActuatorActuateType?

    private init() {
        setupMultitouchSupport()
        prepareHaptics()
    }
    
    private func setupMultitouchSupport() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport", RTLD_NOW)
        guard handle != nil else { return }
        
        let symCreate = dlsym(handle, "MTActuatorCreateFromDeviceID")
        let symOpen = dlsym(handle, "MTActuatorOpen")
        let symActuate = dlsym(handle, "MTActuatorActuate")
        
        guard let symCreate = symCreate, let symOpen = symOpen, let symActuate = symActuate else { return }
        
        let createFn = unsafeBitCast(symCreate, to: MTActuatorCreateFromDeviceIDType.self)
        let openFn = unsafeBitCast(symOpen, to: MTActuatorOpenType.self)
        self.mtActuateFn = unsafeBitCast(symActuate, to: MTActuatorActuateType.self)
        
        if let deviceID = findMultitouchID() {
            if let actuator = createFn(deviceID) {
                if openFn(actuator) == 0 {
                    self.mtActuator = actuator
                }
            }
        }
    }
    
    private func findMultitouchID() -> UInt64? {
        let service = IOServiceMatching("AppleMultitouchDevice")
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, service, &iterator) == KERN_SUCCESS {
            var device = IOIteratorNext(iterator)
            while device != 0 {
                if let property = IORegistryEntryCreateCFProperty(device, "Multitouch ID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                    IOObjectRelease(device)
                    IOObjectRelease(iterator)
                    return property.uint64Value
                }
                device = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        
        let service2 = IOServiceMatching("AppleMultitouchTrackpadHIDEventDriver")
        var iterator4: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, service2, &iterator4) == KERN_SUCCESS {
            var device = IOIteratorNext(iterator4)
            while device != 0 {
                if let property = IORegistryEntryCreateCFProperty(device, "mt-device-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                    IOObjectRelease(device)
                    IOObjectRelease(iterator4)
                    return property.uint64Value
                }
                device = IOIteratorNext(iterator4)
            }
            IOObjectRelease(iterator4)
        }
        return nil
    }
    
    func prepareHaptics() {
        guard isSupported else { return }
        
        do {
            engine = try CHHapticEngine()
            
            engine?.stoppedHandler = { reason in
                print("Haptic Engine Stopped: \(reason)")
                self.isPlaying = false
            }
            
            engine?.resetHandler = { [weak self] in
                print("Haptic Engine Reset")
                try? self?.engine?.start()
                self?.setupContinuousPattern()
            }
            
            try engine?.start()
            setupContinuousPattern()
            
        } catch {
            print("Failed to start Haptic Engine: \(error)")
        }
    }
    
    private func setupContinuousPattern() {
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0)
        
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: .greatestFiniteMagnitude)
        
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            continuousPlayer = try engine?.makeAdvancedPlayer(with: pattern)
            try continuousPlayer?.start(atTime: 0)
            isPlaying = true
        } catch {
            print("Failed to setup continuous pattern: \(error)")
        }
    }
    
    /// Called from Audio Thread (~30-60 fps)
    func updateHapticFeedback(deepBass: Float, standardBass: Float) {
        queue.async {
            self.internalUpdateHapticFeedback(deepBass: deepBass, standardBass: standardBass)
        }
    }
    
    private func internalUpdateHapticFeedback(deepBass: Float, standardBass: Float) {
        guard UserDefaults.standard.bool(forKey: "hapticEnabled") else {
            stop()
            return
        }
        
        if let player = continuousPlayer, isPlaying {
            // Update continuous haptics if supported
        } else if isSupported && !isPlaying && UserDefaults.standard.bool(forKey: "hapticEnabled") {
            try? engine?.start()
            try? continuousPlayer?.start(atTime: 0)
            isPlaying = true
        }
        
        let now = Date().timeIntervalSince1970
        let deltaT = now - lastTransientTime
        
        // Use the maximum energy for continuous fatigue tracking
        let maxAmplitude = max(deepBass, standardBass)
        
        // 1. Damping / Fatigue logic
        if maxAmplitude > 0.3 {
            continuousDuration += 0.016
        } else {
            continuousDuration = max(0, continuousDuration - 0.05)
        }
        let dampingFactor: Float = continuousDuration > 1.5 ? 0.4 : 1.0
        
        // Continuous haptics map to overall low energy
        let mappedAmplitude = max(0, maxAmplitude - 0.1)
        let intensityValue = min(max(pow(mappedAmplitude, 2.0) * 2.0 * dampingFactor, 0.0), 1.0)
        let sharpnessValue = min(max(mappedAmplitude * dampingFactor, 0.0), 1.0)
        
        if let player = continuousPlayer, isPlaying {
            let intensityParam = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensityValue, relativeTime: 0)
            let sharpnessParam = CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpnessValue, relativeTime: 0)
            do {
                try player.sendParameters([intensityParam, sharpnessParam], atTime: CHHapticTimeImmediate)
            } catch {
                print("Failed to update dynamic parameters: \(error)")
            }
        }
        
        // 2. Beat/Transient Extraction (Delta Onset Detection)
        let deepDelta = deepBass - lastDeepBass
        let stdDelta = standardBass - lastStandardBass
        
        lastDeepBass = deepBass
        lastStandardBass = standardBass
        
        // Only trigger on sharp rising edges (Attack phase of the kick)
        // 120ms debounce allows up to 8 fast kicks per second, preventing stuttering on sustain
        if deltaT > 0.12 {
            if deepDelta > 0.15 && deepBass > standardBass * 0.8 {
                // MASSIVE HIT for Deep Sub-Bass (20-50Hz)
                if let actuator = mtActuator, let actuateFn = mtActuateFn {
                    lastTransientTime = now
                    _ = actuateFn(actuator, 6, 0, 1.0, 0.0) // Deep Heavy Thump with max volume
                    
                    // Double up the force by also hitting the public API
                    DispatchQueue.main.async {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    }
                } else {
                    lastTransientTime = now
                    DispatchQueue.main.async {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    }
                }
            } else if stdDelta > 0.15 {
                // STANDARD HIT for Punchy Mid-Bass (50-120Hz)
                if let actuator = mtActuator, let actuateFn = mtActuateFn {
                    lastTransientTime = now
                    _ = actuateFn(actuator, 3, 0, 0.0, 0.0) // Standard Heavy Thump
                } else {
                    lastTransientTime = now
                    DispatchQueue.main.async {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    }
                }
            }
        }
    }
    
    func stop() {
        queue.async {
            try? self.continuousPlayer?.stop(atTime: 0)
            try? self.engine?.stop()
            self.isPlaying = false
        }
    }
}
