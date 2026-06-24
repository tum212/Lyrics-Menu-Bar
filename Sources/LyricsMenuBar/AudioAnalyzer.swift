import Foundation
import AVFoundation
import AVFAudio
import Accelerate
import CoreAudio
import CoreMedia
#if os(macOS)
import AppKit
#endif
import Combine

// MARK: - AudioAnalyzer
// Uses AVAudioEngine tapping the system output device via CoreAudio.
// This is the same approach used by Liqoria — it shows "System Audio Recording Only"
// indicator (waveform icon, separate category) rather than the "Screen Recording" indicator.
// No ScreenCaptureKit is used here.

public final class AudioAnalyzer: NSObject, ObservableObject, @unchecked Sendable {
    @Published public var amplitudes: [CGFloat] = Array(repeating: 0.05, count: 14)

    private var engine: AVAudioEngine?
    private var isRunning = false
    public private(set) var bandCount = 14
    private var spectrumBuffer = [Float](repeating: 0, count: 14)
    private var bandGains = [Float](repeating: 0.05, count: 14)
    private let lock = NSLock()

    // Pre-allocated FFT buffers
    private var fftRealP:     [Float] = []
    private var fftImagP:     [Float] = []
    private var fftMagnitudes:[Float] = []
    private var fftWindow:    [Float] = []
    private var fftWindowed:  [Float] = []
    private var fftActual:    [Float] = []

    // Silence Detection
    private var silenceFrames: Int = 0
    private let silenceThresholdFrames: Int = 300
    private var diagnosticShown: Bool = false

    private var bassPeak: Float = 0.0001
    private var cachedFFTSetup: FFTSetup?
    private var cachedLog2n: vDSP_Length = 0
    private var observers: [Any] = []

    public override init() {
        super.init()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let setup = cachedFFTSetup { vDSP_destroy_fftsetup(setup) }
    }

    public func updateBandCount(_ count: Int) {
        guard count > 0, count != bandCount else { return }
        lock.lock()
        defer { lock.unlock() }
        bandCount = count
        spectrumBuffer = [Float](repeating: 0, count: count)
        bandGains = [Float](repeating: 0.05, count: count)
    }

    public func start() {
        guard !isRunning else { return }
        requestAccessAndSetup()
    }

    public func stop() {
        guard isRunning else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        isRunning = false
        DispatchQueue.main.async {
            self.amplitudes = Array(repeating: 0.0, count: self.bandCount)
        }
    }

    // MARK: - Permission & Setup

    private var isRequestingAccess = false

    private func requestAccessAndSetup() {
        guard !isRequestingAccess else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            setupEngine()
        case .notDetermined:
            isRequestingAccess = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isRequestingAccess = false
                    if granted {
                        self?.setupEngine()
                    } else {
                        self?.showPermissionAlert()
                    }
                }
            }
        default:
            DispatchQueue.main.async { self.showPermissionAlert() }
        }
    }

    #if os(macOS)
    private var hasShownAlert = false

    @MainActor
    private func showPermissionAlert() {
        guard !hasShownAlert else { return }
        hasShownAlert = true
        let alert = NSAlert()
        alert.messageText = "System Audio Recording Access Required"
        alert.informativeText = "Lyrics Menu Bar needs access to capture system audio for the waveform visualizer. Please enable it in System Settings → Privacy & Security → System Audio Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            // System Audio Recording Only section
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudioRecording")!
            NSWorkspace.shared.open(url)
        }
    }
    #endif

    // MARK: - AVAudioEngine Setup (CoreAudio system output tap)

    private func setupEngine() {
        let newEngine = AVAudioEngine()

        // ── Wire the engine's input to the system's default output device ─────
        // This is the CoreAudio trick: route the engine's input to the system
        // output device (what's currently playing) rather than the microphone.
        // This is what places the app under "System Audio Recording Only" in Privacy.
        #if os(macOS)
        let inputNode = newEngine.inputNode
        let outputDeviceID = getDefaultOutputDeviceID()
        if let deviceID = outputDeviceID, deviceID != kAudioDeviceUnknown {
            setEngineInputDevice(engine: newEngine, deviceID: deviceID)
        }
        #endif

        let format = newEngine.inputNode.outputFormat(forBus: 0)

        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("⚠️ Invalid audio format from input node")
            DispatchQueue.main.async { self.showPermissionAlert() }
            return
        }

        print("📻 AVAudioEngine format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        newEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] (buf: AVAudioPCMBuffer, _: AVAudioTime) in
            guard let self, let channelData = buf.floatChannelData?[0] else { return }
            let count = Int(buf.frameLength)
            let ptr = UnsafeBufferPointer(start: channelData, count: count)
            self.processFFT(floatData: ptr, count: count, sampleRate: Float(format.sampleRate))
        }

        do {
            try newEngine.start()
            self.engine    = newEngine
            self.isRunning = true
            print("✅ AVAudioEngine system audio tap started")

            // Restart on config change (device switch, sleep/wake)
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: newEngine,
                    queue: .main
                ) { [weak self] _ in
                    print("🔄 Audio config changed — restarting")
                    self?.stop()
                    self?.start()
                }
            )
        } catch {
            print("⚠️ AVAudioEngine start failed: \(error)")
            DispatchQueue.main.async { self.showPermissionAlert() }
        }
    }

    // MARK: - CoreAudio: route engine input → system output device

    #if os(macOS)
    private func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func setEngineInputDevice(engine: AVAudioEngine, deviceID: AudioDeviceID) {
        var deviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if let au = engine.inputNode.audioUnit {
            let result = AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                size
            )
            if result == noErr {
                print("✅ Engine input set to system output device (id=\(deviceID))")
            } else {
                print("⚠️ Could not set input device: OSStatus=\(result)")
            }
        }
    }
    #endif

    // MARK: - Sliding-window FFT

    private let fftSize = 4096
    private var circularBuffer: [Float] = Array(repeating: 0, count: 4096)
    private var circularIndex: Int = 0
    private var lastPrintTime = Date()

    private func processFFT(floatData: UnsafeBufferPointer<Float>, count: Int, sampleRate: Float) {
        let halfLen = fftSize / 2

        if Date().timeIntervalSince(lastPrintTime) > 1.0 {
            var maxVal: Float = 0
            if count > 0 { vDSP_maxv(floatData.baseAddress!, 1, &maxVal, vDSP_Length(count)) }
            print("🔊 Tap. frames=\(count) maxAmp=\(maxVal)")
            lastPrintTime = Date()
        }

        // Lazy-init FFT
        if cachedFFTSetup == nil || fftRealP.count != halfLen {
            if let old = cachedFFTSetup { vDSP_destroy_fftsetup(old) }
            cachedLog2n    = vDSP_Length(log2(Float(fftSize)))
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

        // Fill circular buffer
        let src = floatData.baseAddress!
        for i in 0..<count {
            circularBuffer[circularIndex] = src[i]
            circularIndex = (circularIndex + 1) % fftSize
        }

        // Unwrap into contiguous array
        var latest = [Float](repeating: 0, count: fftSize)
        let tail = fftSize - circularIndex
        if tail > 0 { latest[0..<tail] = circularBuffer[circularIndex..<fftSize] }
        if circularIndex > 0 { latest[tail..<fftSize] = circularBuffer[0..<circularIndex] }

        // Window + FFT
        vDSP_vmul(latest, 1, &fftWindow, 1, &fftWindowed, 1, vDSP_Length(fftSize))
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
        var halfLenI = Int32(halfLen)
        vvsqrtf(&fftActual, &fftMagnitudes, &halfLenI)

        // Band mapping
        let minHz: Float = 60, maxHz: Float = 16000
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
            let boost: Float
            switch centerHz {
            case 60..<200:    boost = 0.7
            case 200..<800:   boost = 2.2
            case 800..<3000:  boost = 3.0
            case 3000..<8000: boost = 2.0
            default:          boost = 1.0
            }
            let boosted = avg * boost
            rawBands[i] = boosted
            if boosted > frameMax { frameMax = boosted }
        }

        // Haptics
        if UserDefaults.standard.bool(forKey: "hapticEnabled") {
            let deepMinBin = max(1, Int(20.0 / hzPerBin))
            let deepMaxBin = min(halfLen - 1, Int(50.0 / hzPerBin))
            let stdMinBin = deepMaxBin
            let stdMaxBin = min(halfLen - 1, Int(120.0 / hzPerBin))
            var deepSum: Float = 0
            if deepMaxBin > deepMinBin { for j in deepMinBin..<deepMaxBin { deepSum += fftActual[j] } }
            let deepAvg = deepSum / max(1, Float(deepMaxBin - deepMinBin))
            var stdSum: Float = 0
            if stdMaxBin > stdMinBin { for j in stdMinBin..<stdMaxBin { stdSum += fftActual[j] } }
            let stdAvg = stdSum / max(1, Float(stdMaxBin - stdMinBin))
            bassPeak = max(bassPeak * 0.92, max(deepAvg, stdAvg))
            let deepNorm = min(1.0, deepAvg / max(bassPeak, 0.0001))
            let stdNorm  = min(1.0, stdAvg  / max(bassPeak, 0.0001))
            DispatchQueue.main.async {
                HapticManager.shared.updateHapticFeedback(deepBass: deepNorm, standardBass: stdNorm)
            }
        }

        // Per-band auto-gain + smoothing
        var newAmplitudes = [CGFloat](repeating: 0.01, count: currentBandCount)
        lock.lock()
        for i in 0..<currentBandCount {
            let val = rawBands[i]
            bandGains[i] = val > bandGains[i]
                ? bandGains[i] * 0.4 + val * 0.6
                : bandGains[i] * 0.98 + val * 0.02
            let ref = max(bandGains[i], 0.00001)
            var scaled = min(1.0, max(0.01, val / ref))
            if frameMax < 0.00005 { scaled = 0.01 }
            scaled = pow(scaled, 0.5)
            let cur = spectrumBuffer[i]
            spectrumBuffer[i] = scaled > cur ? cur * 0.3 + scaled * 0.7 : cur * 0.5 + scaled * 0.5
            newAmplitudes[i] = CGFloat(spectrumBuffer[i])
        }
        lock.unlock()

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

        DispatchQueue.main.async { self.amplitudes = newAmplitudes }
    }
}
