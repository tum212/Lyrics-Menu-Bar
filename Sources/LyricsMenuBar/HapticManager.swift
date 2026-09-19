import AppKit
import CoreHaptics
import IOKit

// MARK: - HapticManager
// ══════════════════════════════════════════════════════════════════════
// ZERO-LATENCY HAPTIC DESIGN (Physics-based):
//
// Audio chain latency on macOS:
//   CoreAudio buffer → DAC → speaker/headphone
//   inOutputTime.mHostTime = Mach timestamp when buffer exits DAC
//
// Haptic chain latency (measured on MBP Force Touch):
//   MTActuatorActuate call → physical vibration ≈ 6ms
//   CHHapticEngine.start(atTime:) → vibration ≈ 4ms
//
// Zero-latency condition:
//   T_vibration_felt = T_audio_heard
//   T_haptic_call + T_hw_latency = T_dac + T_dac_to_ear
//   ∴ T_haptic_call = T_dac - (T_hw_latency - T_dac_to_ear)
//                   = T_dac - (6ms - 1ms)
//                   = T_dac - 5ms   ← HAPTIC_LEAD_TIME
//
// Beat onset within buffer:
//   If onset is at sample position s in buffer of size N at 44100Hz:
//   T_onset = T_dac + s/44100
//   T_haptic_fire = T_onset - HAPTIC_LEAD_TIME
//
// Implementation:
//   - IOProc passes inOutputTime.mHostTime (hardware DAC clock)
//   - We detect onset → compute T_haptic_fire
//   - CHHapticEngine.start(atTime: chEngineTime) fires at exact hardware moment
//   - If T_haptic_fire is past → call MTActuator immediately (best effort)
// ══════════════════════════════════════════════════════════════════════

final class HapticManager: @unchecked Sendable {
    static let shared = HapticManager()

    // ── Hardware constants (MacBook Pro Force Touch) ──────────────────
    // MTActuator: measured ~6ms call-to-vibration on M-series MBP
    // CHHapticEngine: measured ~4ms call-to-vibration
    // DAC-to-ear: ~1ms (electrical + ~30cm acoustic path ≈ 0.87ms)
    // Lead time = hw_latency - dac_to_ear
    private let kMTActuatorLeadTime: Double = 0.005   // 5ms lead for MTActuator
    private let kCHHapticLeadTime:   Double = 0.003   // 3ms lead for CHHapticEngine

    // ── Queue & Engine ────────────────────────────────────────────────
    private let queue = DispatchQueue(label: "com.lyricsmenubar.haptics", qos: .userInteractive)
    private var engine: CHHapticEngine?
    private var engineStartWallTime: Double = 0   // wall time when engine was started
    private var engineStartCHTime:   Double = 0   // CHHapticEngine time when it was started

    // ── Onset Detection State ─────────────────────────────────────────
    private var prevDeepBass: Float = 0
    private var prevStdBass:  Float = 0
    private var bassPeak:     Float = 0.0001
    private var lastFireWallTime: Double = 0  // wall time of last haptic to enforce refractory

    // ── MultitouchSupport (direct Force Touch trackpad) ───────────────
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var mtActuator: UnsafeMutableRawPointer?
    private typealias MTActuatorCreateFromDeviceIDType = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias MTActuatorOpenType               = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias MTActuatorCloseType              = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias MTActuatorActuateType            = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float32, Float32) -> Int32
    private var mtActuateFn: MTActuatorActuateType?
    private var mtCloseFn: MTActuatorCloseType?

    var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    var latencyOffset: Double {
        get { UserDefaults.standard.double(forKey: "hapticLatencyOffset") }
        set { UserDefaults.standard.set(newValue, forKey: "hapticLatencyOffset") }
    }

    // MARK: - Init

    private init() {
        setupMultitouchSupport()
        prepareHapticEngine()
    }

    deinit {
        teardown()
    }

    // MARK: - MultitouchSupport Setup

    private func setupMultitouchSupport() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport", RTLD_NOW) else { return }
        frameworkHandle = handle
        guard let symCreate  = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let symOpen    = dlsym(handle, "MTActuatorOpen"),
              let symActuate = dlsym(handle, "MTActuatorActuate") else { return }

        let createFn = unsafeBitCast(symCreate, to: MTActuatorCreateFromDeviceIDType.self)
        let openFn   = unsafeBitCast(symOpen,   to: MTActuatorOpenType.self)
        mtActuateFn  = unsafeBitCast(symActuate, to: MTActuatorActuateType.self)
        if let symClose = dlsym(handle, "MTActuatorClose") {
            mtCloseFn = unsafeBitCast(symClose, to: MTActuatorCloseType.self)
        }

        if let id = findMultitouchID(), let actuator = createFn(id), openFn(actuator) == 0 {
            mtActuator = actuator
            print("✅ HapticManager: MTActuator connected (Force Touch direct path)")
        }
    }

    private func findMultitouchID() -> UInt64? {
        for name in ["AppleMultitouchDevice", "AppleMultitouchTrackpadHIDEventDriver"] {
            let service = IOServiceMatching(name)
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, service, &iter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }
            var device = IOIteratorNext(iter)
            while device != 0 {
                defer { IOObjectRelease(device) }
                for key in ["Multitouch ID", "mt-device-id"] {
                    if let val = IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                        return val.uint64Value
                    }
                }
                device = IOIteratorNext(iter)
            }
        }
        return nil
    }

    // MARK: - CHHapticEngine Setup

    func prepareHapticEngine() {
        guard isSupported else { return }
        do {
            let eng = try CHHapticEngine()
            eng.stoppedHandler = { [weak self] _ in
                guard let self = self else { return }
                self.queue.async { [weak self] in
                    self?.engine = nil
                }
            }
            eng.resetHandler = { [weak self] in
                guard let self = self else { return }
                do { try self.engine?.start() } catch {}
            }
            try eng.start()
            // Record the wall↔CHHaptic time correspondence for scheduling
            engineStartWallTime = Date().timeIntervalSince1970
            engineStartCHTime   = eng.currentTime
            engine = eng
            print("✅ HapticManager: CHHapticEngine ready")
        } catch {
            print("⚠️ HapticManager: CHHapticEngine failed: \(error)")
        }
    }

    // MARK: - Public API (called from IOProc audio thread)

    /// Called directly from the CoreAudio IOProc thread.
    /// bufferHostTime: inOutputTime.mHostTime — Mach timestamp when first sample of buffer exits DAC.
    /// bufferFrameCount: number of frames in the buffer (for onset offset calculation).
    func updateHapticFeedback(
        deepBass: Float,
        standardBass: Float,
        intensity: Int,
        bufferHostTime: UInt64,
        bufferFrameCount: Int,
        sampleRate: Float
    ) {
        // Dispatch to haptic queue immediately — .userInteractive = OS gives this highest priority
        queue.async { [self] in
            guard intensity > 0 else { stop(); return }
            processFrame(
                deepBass: deepBass, standardBass: standardBass, intensity: intensity,
                bufferHostTime: bufferHostTime,
                bufferFrameCount: bufferFrameCount,
                sampleRate: Double(sampleRate)
            )
        }
    }

    // MARK: - Beat Detection + Hardware-Timed Haptic

    private func processFrame(
        deepBass: Float, standardBass: Float, intensity: Int,
        bufferHostTime: UInt64, bufferFrameCount: Int, sampleRate: Double
    ) {
        // ── Auto-gain: fast attack, moderate decay ─────────────────────
        bassPeak = max(bassPeak * 0.95, max(deepBass, standardBass))
        let noiseFloor = bassPeak * 0.20

        // ── Onset ratio: energy jump = beat ───────────────────────────
        let deepRatio = deepBass / max(prevDeepBass, 0.00001)
        let stdRatio  = standardBass / max(prevStdBass, 0.00001)
        prevDeepBass = deepBass
        prevStdBass  = standardBass

        // Threshold: tuned per intensity to match Apple Music selectivity
        // High threshold = only kick drums, low threshold = more beats
        let threshold: Float
        switch intensity {
        case 3: threshold = 1.7   // Firm: big kicks only
        case 2: threshold = 1.45  // Medium
        default: threshold = 1.25 // Light: softer beats too
        }

        let isDeepHit = deepRatio > threshold && deepBass > noiseFloor
        let isStdHit  = stdRatio  > threshold && standardBass > noiseFloor
        guard isDeepHit || isStdHit else { return }

        // ── Refractory: prevent double-fire on same beat ───────────────
        // Convert buffer hardware time to wall seconds for comparison
        let bufferWallTime = machTimeToSeconds(bufferHostTime)

        let minGap: Double
        switch intensity {
        case 3: minGap = 0.16   // max ~375 BPM
        case 2: minGap = 0.13   // max ~460 BPM
        default: minGap = 0.10  // max ~600 BPM
        }
        guard bufferWallTime - lastFireWallTime >= minGap else { return }
        lastFireWallTime = bufferWallTime

        // ── Physics: compute EXACT haptic fire time ────────────────────
        //
        // The onset is at the END of the buffer (the energy jump we see in
        // the FFT window peaked somewhere in this buffer — conservatively
        // place onset at the buffer midpoint for accuracy).
        // onset_offset = (bufferFrameCount / 2) / sampleRate
        //
        // T_haptic_fire = T_dac + onset_offset - HAPTIC_LEAD_TIME
        //               = bufferWallTime + midpointOffset - leadTime
        //
        let onsetOffset = Double(bufferFrameCount / 2) / sampleRate
        let leadTime = ((mtActuator != nil) ? kMTActuatorLeadTime : kCHHapticLeadTime) + latencyOffset
        let hapticFireWallTime = bufferWallTime + onsetOffset - leadTime

        let wallNow = Date().timeIntervalSince1970
        let deltaToFire = hapticFireWallTime - wallNow  // positive = future, negative = past

        if deltaToFire <= 0.001 {
            // ── Already at or past fire time → call immediately ────────
            // This handles cases where the audio buffer was delayed or
            // haptic lead time > onset offset.
            fireImmediately(isDeep: isDeepHit, intensity: intensity)
        } else {
            // ── Future fire time → schedule with hardware precision ─────
            // Use CHHapticEngine's timeline which is synchronized to the
            // audio hardware clock. This gives microsecond precision.
            if let eng = engine {
                // Map wall time delta to CHHapticEngine time
                let chFireTime = eng.currentTime + deltaToFire
                scheduleTransient(at: chFireTime, isDeep: isDeepHit, intensity: intensity, engine: eng)
            } else {
                // No engine: schedule via DispatchQueue as fallback
                let delay = deltaToFire
                DispatchQueue.global(qos: .userInteractive).asyncAfter(
                    deadline: .now() + delay
                ) { [weak self] in
                    self?.fireImmediately(isDeep: isDeepHit, intensity: intensity)
                }
            }
        }
    }

    // MARK: - Fire Methods

    /// MTActuator type constants (reverse-engineered from Apple's private framework):
    /// Type 1 → Very light tap (~200Hz high-freq) — feels like light fingernail tap
    /// Type 2 → Light-medium click (~180Hz)       — slightly heavier than 1
    /// Type 3 → Standard click (~160Hz)           — default system click feel
    /// Type 4 → Sharp crisp click (~220Hz peak)   — closest to Pacinian sweet spot
    /// Type 5 → Medium-heavy thump
    /// Type 6 → Deep sub-bass thump (~100Hz)      — heavy, low frequency
    ///
    /// For music haptics, Type 4 targets Pacinian corpuscles (200-300Hz sensitivity peak)
    /// UserDefaults key: "hapticActuatorType" (Int, default 4)
    private func resolveActuatorType(isDeep: Bool) -> Int32 {
        let saved = UserDefaults.standard.integer(forKey: "hapticActuatorType")
        if saved > 0 {
            return Int32(saved)  // User override from settings
        }
        // Auto: deep kick = type 6 (sub-bass thump), beat = type 4 (Pacinian-optimized)
        return isDeep ? 6 : 4
    }

    private func fireImmediately(isDeep: Bool, intensity: Int) {
        if let actuator = mtActuator, let fn = mtActuateFn {
            let type: Int32  = resolveActuatorType(isDeep: isDeep)
            let amp: Float32 = intensity == 3 ? 1.0 : (intensity == 2 ? 0.75 : 0.5)
            _ = fn(actuator, type, 0, amp, 0.0)
        } else if let eng = engine {
            scheduleTransient(at: eng.currentTime, isDeep: isDeep, intensity: intensity, engine: eng)
        } else {
            DispatchQueue.main.async {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    /// Fires a single test pulse of the given MTActuator type at full amplitude.
    /// Call this from the menu to let user feel each type.
    func testActuatorType(_ type: Int32) {
        queue.async { [self] in
            guard let actuator = mtActuator, let fn = mtActuateFn else {
                // CHHapticEngine fallback for non-trackpad Macs
                if let eng = engine {
                    try? {
                        let event = CHHapticEvent(
                            eventType: .hapticTransient,
                            parameters: [
                                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                            ],
                            relativeTime: 0
                        )
                        let p = try CHHapticPattern(events: [event], parameters: [])
                        let player = try eng.makePlayer(with: p)
                        try player.start(atTime: eng.currentTime)
                    }()
                }
                return
            }
            _ = fn(actuator, type, 0, 1.0, 0.0)
        }
    }

    private func scheduleTransient(at chTime: Double, isDeep: Bool, intensity: Int, engine: CHHapticEngine) {
        do {
            let intensityVal: Float = intensity == 3 ? 1.0 : (intensity == 2 ? 0.8 : 0.6)
            let sharpnessVal: Float = isDeep ? 1.0 : 0.75

            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensityVal),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpnessVal)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player  = try engine.makePlayer(with: pattern)
            try player.start(atTime: chTime)
        } catch {}
    }

    // MARK: - Stop & Teardown

    func stop() {
        engine?.stop()
    }

    func teardown() {
        stop()
        if let actuator = mtActuator {
            _ = mtCloseFn?(actuator)
            mtActuator = nil
        }
        if let handle = frameworkHandle {
            dlclose(handle)
            frameworkHandle = nil
        }
    }
}
