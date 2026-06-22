import Foundation

final class PhaseLockedLoop: @unchecked Sendable {
    // Current oscillator state
    var frequency: Double = 2.0 // Starts at 120 BPM (2.0 Hz)
    var phase: Double = 0.0
    
    // Tuning parameters for PI Controller
    private let alpha: Double = 0.02 // Frequency adjustment (BPM tracking speed)
    private let beta: Double = 0.15  // Phase adjustment (Beat alignment speed)
    
    // Predictive triggering
    private let triggerThreshold: Double = 0.95 // Fire slightly early to compensate for mechanical latency
    private var hasTriggeredForCurrentBeat = false
    
    /// Advances the PLL by delta time. Returns true if a beat should be triggered.
    func advance(by deltaT: TimeInterval) -> Bool {
        let previousPhase = phase
        let newPhase = phase + frequency * deltaT
        
        phase = newPhase.truncatingRemainder(dividingBy: 1.0)
        
        // Did we cross the threshold for this beat?
        var shouldTrigger = false
        if newPhase >= triggerThreshold && previousPhase < triggerThreshold {
            shouldTrigger = true
            hasTriggeredForCurrentBeat = true
        } else if newPhase >= 1.0 && !hasTriggeredForCurrentBeat {
            // Fallback in case deltaT was large enough to skip the threshold entirely
            shouldTrigger = true
            hasTriggeredForCurrentBeat = true
        }
        
        // Reset the trigger lock once we wrap completely around
        if newPhase >= 1.0 {
            hasTriggeredForCurrentBeat = false
        }
        
        return shouldTrigger
    }
    
    /// Called when the onset detector finds a strong transient (e.g. a kick drum).
    func registerOnset() {
        // Calculate shortest phase error: from -0.5 to +0.5
        // If phase is 0.1, error is 0.1 (onset is slightly late)
        // If phase is 0.9, error is -0.1 (onset is slightly early)
        let error = phase < 0.5 ? phase : (phase - 1.0)
        
        // PI Update
        frequency -= alpha * error
        phase -= beta * error
        
        // Clamp frequency to realistic BPMs: 70 BPM (1.16 Hz) to 180 BPM (3.0 Hz)
        frequency = max(1.16, min(frequency, 3.0))
        
        // Ensure phase stays bound [0, 1)
        if phase < 0 { phase += 1.0 }
        if phase >= 1.0 { phase -= 1.0 }
    }
    
    func reset() {
        frequency = 2.0
        phase = 0.0
        hasTriggeredForCurrentBeat = false
    }
}
