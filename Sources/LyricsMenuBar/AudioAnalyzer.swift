import Foundation
import AVFoundation
import Accelerate
#if os(macOS)
import AppKit
#endif
import CoreAudio
import Combine

public final class AudioAnalyzer: ObservableObject, @unchecked Sendable {
    @Published public var amplitudes: [CGFloat] = Array(repeating: 0.05, count: 14)

    private var engine: AVAudioEngine = AVAudioEngine()
    private var isRunning = false

    public private(set) var bandCount = 14
    private var spectrumBuffer = [Float](repeating: 0, count: 14)
    private var bandGains = [Float](repeating: 0.05, count: 14)
    private let lock = NSLock()

    // Pre-allocated FFT buffers — avoid per-frame heap allocation
    private var fftRealP:     [Float] = []
    private var fftImagP:     [Float] = []
    private var fftMagnitudes:[Float] = []
    private var fftWindow:    [Float] = []
    private var fftWindowed:  [Float] = []
    private var fftActual:    [Float] = []
    
    // Silence Detection
    private var silenceFrames: Int = 0
    private let silenceThresholdFrames: Int = 300 // ~5 seconds at 60fps
    private var diagnosticShown: Bool = false
    
    private var bassPeak: Float = 0.0001
    private var cachedFFTSetup: FFTSetup?
    private var cachedLog2n: vDSP_Length = 0
    private var observers: [Any] = []

    public init() {
        // Observe audio engine configuration changes (e.g. sleep/wake, device changes)
        observers.append(
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                print("🔄 Audio engine configuration changed (e.g., wake from sleep). Restarting...")
                self?.restartEngine()
            }
        )
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API
    
    public func updateBandCount(_ count: Int) {
        guard count > 0, count != bandCount else { return }
        lock.lock()
        defer { lock.unlock() }
        bandCount = count
        spectrumBuffer = [Float](repeating: 0, count: count)
        bandGains = [Float](repeating: 0.05, count: count)
    }

    private var isRequestingAccess = false

    public func start() {
        guard !isRunning else { return }
        guard !isRequestingAccess else { return }

        #if os(macOS)
        // Always request mic permission first because macOS requires it for ALL audio input streams (including virtual ones like BlackHole)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            setupAudio()
        case .notDetermined:
            isRequestingAccess = true
            print("🎙️ Microphone permission not determined — requesting access...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isRequestingAccess = false
                    if granted {
                        print("✅ Microphone permission granted")
                        self?.setupAudio()
                    } else {
                        print("❌ Microphone permission denied")
                        self?.showPermissionAlert()
                    }
                }
            }
        default:
            print("⚠️ Microphone access denied. Please enable it in System Settings -> Privacy & Security -> Microphone.")
            DispatchQueue.main.async { self.showPermissionAlert() }
        }
        #else
        setupAudio()
        #endif
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        // removeTap only if tap exists — avoid crash on double-stop
        do { engine.inputNode.removeTap(onBus: 0) } catch {}
        engine.reset()      // ← must reset so BlackHole device can be re-set on next start()
        isRunning = false
        DispatchQueue.main.async {
            self.amplitudes = Array(repeating: 0.0, count: 10)
        }
    }
    
    private var lastRestartTime: Date = .distantPast

    private func restartEngine() {
        guard isRunning else { return }
        
        // Prevent rapid restart loops
        let now = Date()
        guard now.timeIntervalSince(lastRestartTime) > 2.0 else {
            print("⚠️ Skipping rapid engine restart")
            return
        }
        lastRestartTime = now
        
        stop()
        start()
    }

    #if os(macOS)
    private var hasShownPermissionAlert = false

    private func showPermissionAlert() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true
        
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Lyrics Menu Bar needs Microphone access to read audio from BlackHole for the visualizer. Please enable it in System Settings -> Privacy & Security -> Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    #endif

    // MARK: - Private setup

    private func setupAudio() {
        // Fresh engine each session (reset() invalidates internal state)
        engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Remove forced AudioUnitSetProperty. Since BlackHole is the default input,
        // AVAudioEngine will pick it up automatically, exactly like our test script.
        /*
        #if os(macOS)
        if let blackHoleID = getBlackHoleDeviceID() {
            var deviceID = blackHoleID
            let size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if let au = inputNode.audioUnit {
                let result = AudioUnitSetProperty(au,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, size)
                if result == noErr {
                    print("✅ BlackHole set as audio input (deviceID=\(blackHoleID))")
                } else {
                    print("⚠️ Failed to set BlackHole: OSStatus=\(result)")
                }
            }
        }
        #endif
        */

        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("⚠️ Invalid audio format: ch=\(format.channelCount) sr=\(format.sampleRate)")
            return
        }
        print("📻 Audio format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.process(buffer: buf)
        }

        do {
            try engine.start()
            isRunning = true
            print("✅ Audio engine started")
        } catch {
            print("⚠️ Engine start failed: \(error)")
        }
    }

    // MARK: - BlackHole detection (finds INPUT-capable device named "blackhole")

    #if os(macOS)
    private func getBlackHoleDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr
        else { return nil }

        for id in ids {
            // Check device name
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var name: Unmanaged<CFString>?
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
                  let cfName = name?.takeRetainedValue(),
                  (cfName as String).lowercased().contains("blackhole")
            else { continue }

            print("✅ Found BlackHole input device: \(cfName as String) (id=\(id))")
            return id
        }
        return nil
    }
    #endif

    // MARK: - FFT Processing
    
    // Sliding Window Buffer for low latency + high resolution
    private let fftSize = 4096
    private var circularBuffer: [Float] = Array(repeating: 0, count: 4096)
    private var circularIndex: Int = 0

    private var lastPrintTime = Date()

    private func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        let halfLen = fftSize / 2
        
        if Date().timeIntervalSince(lastPrintTime) > 1.0 {
            let maxVal = (0..<frameLength).reduce(0.0 as Float) { max($0, abs(channelData[$1])) }
            print("🔊 Tap running. FrameLength: \(frameLength), Max Amplitude: \(maxVal)")
            lastPrintTime = Date()
        }

        // Lazy-init cached FFT
        if cachedFFTSetup == nil || fftRealP.count != halfLen {
            if let old = cachedFFTSetup { vDSP_destroy_fftsetup(old) }
            cachedLog2n   = vDSP_Length(log2(Float(fftSize)))
            cachedFFTSetup = vDSP_create_fftsetup(cachedLog2n, FFTRadix(kFFTRadix2))
            fftRealP      = [Float](repeating: 0, count: halfLen)
            fftImagP      = [Float](repeating: 0, count: halfLen)
            fftMagnitudes = [Float](repeating: 0, count: halfLen)
            fftWindow     = [Float](repeating: 0, count: fftSize)
            fftWindowed   = [Float](repeating: 0, count: fftSize)
            fftActual     = [Float](repeating: 0, count: halfLen)
            vDSP_hann_window(&fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }
        guard let fftSetup = cachedFFTSetup else { return }

        // 1. Insert new frames into circular buffer
        for i in 0..<frameLength {
            circularBuffer[circularIndex] = channelData[i]
            circularIndex = (circularIndex + 1) % fftSize
        }
        
        // 2. Extract latest `fftSize` frames chronologically
        var latestFrames = [Float](repeating: 0, count: fftSize)
        let tailLen = fftSize - circularIndex
        if tailLen > 0 {
            latestFrames[0..<tailLen] = circularBuffer[circularIndex..<fftSize]
        }
        if circularIndex > 0 {
            latestFrames[tailLen..<fftSize] = circularBuffer[0..<circularIndex]
        }

        // Window + FFT (zero allocation)
        vDSP_vmul(latestFrames, 1, &fftWindow, 1, &fftWindowed, 1, vDSP_Length(fftSize))

        fftWindowed.withUnsafeBufferPointer { wPtr in
            wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfLen) { cPtr in
                fftRealP.withUnsafeMutableBufferPointer { rPtr in
                    fftImagP.withUnsafeMutableBufferPointer { iPtr in
                        var sc = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                        vDSP_ctoz(cPtr, 2, &sc, 1, vDSP_Length(halfLen))
                        vDSP_fft_zrip(fftSetup, &sc, 1, cachedLog2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&sc, 1, &fftMagnitudes, 1, vDSP_Length(halfLen))
                    }
                }
            }
        }

        // Vectorised sqrt
        var halfLenI = Int32(halfLen)
        vvsqrtf(&fftActual, &fftMagnitudes, &halfLenI)

        // --- Frequency band mapping ---
        // sampleRate ÷ fftSize = Hz per bin (e.g. 44100 / 4096 = 10.76 Hz)
        let sampleRate = Float(44100)  // conservative default
        let minHz: Float = 60.0
        let maxHz: Float = 16000.0
        let hzPerBin = sampleRate / Float(fftSize)

        lock.lock()
        let currentBandCount = bandCount
        lock.unlock()

        var rawBands = [Float](repeating: 0, count: currentBandCount)
        var frameMax: Float = 0.000001

        for i in 0..<currentBandCount {
            let ratio    = Float(i) / Float(max(1, currentBandCount - 1))
            let centerHz = minHz * pow(maxHz / minHz, ratio)
            let centerBin = Int(centerHz / hzPerBin)
            let span = max(1, Int(Float(centerBin) * 0.15))
            let lo = max(1, centerBin - span / 2)
            let hi = min(halfLen - 1, lo + span)

            var sum: Float = 0
            for j in lo..<hi { sum += fftActual[j] }
            let avg = sum / Float(max(1, hi - lo))

            // --- Dynamic Island–style vocal-range boost ---
            // Vocals: 200 Hz – 3 kHz → big boost
            // Presence: 3 – 8 kHz   → moderate boost
            // Bass: 60-200 Hz        → slight reduce (less boom)
            let boost: Float
            switch centerHz {
            case 60..<200:    boost = 0.7
            case 200..<800:   boost = 2.2   // low vocals / chest
            case 800..<3000:  boost = 3.0   // main vocal range
            case 3000..<8000: boost = 2.0   // presence / sibilance
            default:          boost = 1.0
            }

            let boosted = avg * boost
            rawBands[i] = boosted
            if boosted > frameMax { frameMax = boosted }
        }

        // --- Raw Bass Extraction for Haptics ---
        if UserDefaults.standard.bool(forKey: "hapticEnabled") {
            let deepMinBin = max(1, Int(20.0 / hzPerBin))
            let deepMaxBin = min(halfLen - 1, Int(50.0 / hzPerBin))
            let stdMinBin = deepMaxBin
            let stdMaxBin = min(halfLen - 1, Int(120.0 / hzPerBin))
            
            var deepSum: Float = 0
            if deepMaxBin > deepMinBin {
                for j in deepMinBin..<deepMaxBin { deepSum += fftActual[j] }
            }
            let deepAvg = deepSum / max(1.0, Float(deepMaxBin - deepMinBin))
            
            var stdSum: Float = 0
            if stdMaxBin > stdMinBin {
                for j in stdMinBin..<stdMaxBin { stdSum += fftActual[j] }
            }
            let stdAvg = stdSum / max(1.0, Float(stdMaxBin - stdMinBin))
            
            bassPeak = max(bassPeak * 0.92, max(deepAvg, stdAvg))
            let deepNorm = min(1.0, deepAvg / max(bassPeak, 0.0001))
            let stdNorm = min(1.0, stdAvg / max(bassPeak, 0.0001))
            
            HapticManager.shared.updateHapticFeedback(deepBass: deepNorm, standardBass: stdNorm)
        }

        // Remove global auto-gain logic
        var newAmplitudes = [CGFloat](repeating: 0.01, count: currentBandCount)
        
        lock.lock()
        for i in 0..<currentBandCount {
            let val = rawBands[i]
            
            // Per-band auto-gain (fast attack, slow decay)
            bandGains[i] = val > bandGains[i]
                ? bandGains[i] * 0.4 + val * 0.6
                : bandGains[i] * 0.98 + val * 0.02
                
            let reference = max(bandGains[i], 0.00001)
            var scaled = min(1.0, max(0.01, val / reference))
            
            // Noise gate: if the entire frame is very quiet, suppress everything
            if frameMax < 0.00005 {
                scaled = 0.01
            }
            
            scaled = pow(scaled, 0.5) // Non-linear curve (square root) makes small movements much more visible
            let current = spectrumBuffer[i]
            // Fast attack (0.7), moderate decay (0.5) — feels alive
            spectrumBuffer[i] = scaled > current
                ? current * 0.3 + scaled * 0.7
                : current * 0.5 + scaled * 0.5
            newAmplitudes[i] = CGFloat(spectrumBuffer[i])
        }
        lock.unlock()
        
        // Silence detection logic
        if frameMax < 0.00005 {
            silenceFrames += 1
            if silenceFrames >= silenceThresholdFrames && !diagnosticShown {
                diagnosticShown = true
                DispatchQueue.main.async {
                    DiagnosticWindowManager.shared.showDiagnostic(issue: .silentAudio)
                }
            }
        } else {
            silenceFrames = 0
        }

        DispatchQueue.main.async {
            self.amplitudes = newAmplitudes
        }
    }
}
