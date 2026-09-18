import Foundation
import AVFoundation
import Accelerate
import CoreMedia
import CoreAudio
#if os(macOS)
import AppKit
#endif
import Combine

// MARK: - Mach time → seconds helper (used in IOProc → Haptic pipeline)
private nonisolated(unsafe) let _machTimebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

@inline(__always)
func machTimeToSeconds(_ t: UInt64) -> Double {
    return Double(t) * Double(_machTimebaseInfo.numer) / Double(_machTimebaseInfo.denom) * 1e-9
}

// MARK: - Global IOProc Callback
func tapIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else { return noErr }
    let analyzer = Unmanaged<AudioAnalyzer>.fromOpaque(clientData).takeUnretainedValue()

    // inOutputTime.mHostTime = exact Mach timestamp when the FIRST sample
    // of this buffer will exit the DAC. This is our anchor for zero-latency haptics.
    let outputHostTime = inOutputTime.pointee.mHostTime

    let bufferListPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    if bufferListPtr.count > 0 {
        let buffer = bufferListPtr[0]
        let byteSize = Int(buffer.mDataByteSize)
        let frameCount = byteSize / MemoryLayout<Float32>.size
        if let data = buffer.mData, frameCount > 0 {
            let floatData = data.assumingMemoryBound(to: Float32.self)
            let bufferPtr = UnsafeBufferPointer(start: floatData, count: frameCount)
            analyzer.processFloatData(bufferPtr, count: frameCount, sampleRate: 44100.0,
                                      outputHostTime: outputHostTime)
        }
    }

    return noErr
}

// MARK: - AudioAnalyzer

public final class AudioAnalyzer: NSObject, ObservableObject, @unchecked Sendable {
    @Published public var amplitudes: [CGFloat] = Array(repeating: 0.05, count: 14)

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID? = nil
    public private(set) var isRunning = false
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

    private var currentTargetBundleID: String = "com.spotify.client"

    public override init() {
        super.init()
        let obs = NotificationCenter.default.addObserver(forName: Notification.Name("ActiveMusicSourceChanged"), object: nil, queue: .main) { [weak self] notif in
            if let bundleID = notif.userInfo?["bundleID"] as? String {
                self?.retarget(bundleID: bundleID)
            }
        }
        observers.append(obs)
    }

    public func retarget(bundleID: String) {
        guard bundleID != currentTargetBundleID else { return }
        currentTargetBundleID = bundleID
        if isRunning {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.start()
            }
        }
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
        if let ioProcID = ioProcID, aggregateDeviceID != 0 {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            self.ioProcID = nil
            self.aggregateDeviceID = 0
            self.tapID = 0
        }
        isRunning = false
        DispatchQueue.main.async {
            self.amplitudes = Array(repeating: 0.0, count: self.bandCount)
        }
    }

    // MARK: - Permission & Setup

    private var isRequestingAccess = false

    private func requestAccessAndSetup() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        setupCoreAudioTap()
        isRequestingAccess = false
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
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudioRecording")!
            NSWorkspace.shared.open(url)
        }
    }
    #endif

    // MARK: - CoreAudio Tap Setup

    private func setupCoreAudioTap() {
        guard #available(macOS 14.2, *) else {
            print("macOS 14.2+ required for CATapDescription")
            DispatchQueue.main.async { self.showPermissionAlert() }
            return
        }

        var targetBundleID = currentTargetBundleID
        let mode = UserDefaults.standard.string(forKey: "musicSourceMode") ?? "Auto"
        if mode == "Apple Music" {
            targetBundleID = "com.apple.Music"
        } else if mode == "Spotify" {
            targetBundleID = "com.spotify.client"
        } else {
            let spotifyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").contains { !$0.isTerminated }
            let musicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").contains { !$0.isTerminated }
            if musicRunning && !spotifyRunning {
                targetBundleID = "com.apple.Music"
            } else if spotifyRunning {
                targetBundleID = "com.spotify.client"
            }
        }

        let targetApps = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).filter { !$0.isTerminated }
        guard let targetApp = targetApps.first else {
            print("Target music app (\(targetBundleID)) is not running")
            return
        }
        currentTargetBundleID = targetBundleID
        
        var pid: pid_t = pid_t(targetApp.processIdentifier)
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        
        var processID: AudioObjectID = 0
        var processIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            pidSize,
            &pid,
            &processIDSize,
            &processID
        )
        
        guard status == noErr, processID != 0 else {
            print("Failed to translate PID to ProcessObject: \(status)")
            return
        }

        let desc = CATapDescription(stereoMixdownOfProcesses: [processID])
        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        
        guard tapStatus == noErr, newTapID != 0 else {
            print("Failed to create process tap: \(tapStatus)")
            DispatchQueue.main.async { self.showPermissionAlert() }
            return
        }
        
        self.tapID = newTapID
        
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(newTapID, &uidAddress, 0, nil, &uidSize, uidPtr)
        }
        
        let tapDict: [String: Any] = [
            "uid": uid
        ]
        
        let aggregateDict: [String: Any] = [
            "name": "Spoticat Tap Aggregate",
            "uid": UUID().uuidString,
            "private": 1,
            "taps": [tapDict]
        ]
        
        var aggregateID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != 0 else {
            print("Failed to create aggregate device: \(aggStatus)")
            return
        }
        
        self.aggregateDeviceID = aggregateID
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        
        var newIOProcID: AudioDeviceIOProcID? = nil
        let ioStatus = AudioDeviceCreateIOProcID(aggregateID, tapIOProc, clientData, &newIOProcID)
        guard ioStatus == noErr, let validIOProcID = newIOProcID else {
            print("Failed to create IOProc: \(ioStatus)")
            return
        }
        self.ioProcID = validIOProcID
        
        let startStatus = AudioDeviceStart(aggregateID, validIOProcID)
        if startStatus == noErr {
            self.isRunning = true
            print("✅ CoreAudio Process Tap started on \(targetBundleID)!")
        } else {
            print("Failed to start IOProc: \(startStatus)")
        }
    }

    // MARK: - Sliding-window FFT

    private let fftSize = 4096
    private var circularBuffer: [Float] = Array(repeating: 0, count: 4096)
    private var circularIndex: Int = 0
    private var lastPrintTime = Date()
    
    // Bridging call for IOProc — carries the hardware output timestamp for zero-latency haptics
    fileprivate func processFloatData(_ floatData: UnsafeBufferPointer<Float>, count: Int, sampleRate: Float,
                                      outputHostTime: UInt64) {
        processFFT(floatData: floatData, count: count, sampleRate: sampleRate,
                   outputHostTime: outputHostTime)
    }

    private func processFFT(floatData: UnsafeBufferPointer<Float>, count: Int, sampleRate: Float,
                             outputHostTime: UInt64) {
        let halfLen = fftSize / 2

        if Date().timeIntervalSince(lastPrintTime) > 1.0 {
            var maxVal: Float = 0
            if count > 0 { vDSP_maxv(floatData.baseAddress!, 1, &maxVal, vDSP_Length(count)) }
            print("🔊 CoreAudio Tap Frames=\(count) maxAmp=\(maxVal)")
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

        // Haptics — hardware-timestamp-aware for true zero latency
        let hapticIntensity = UserDefaults.standard.integer(forKey: "hapticIntensity")
        if hapticIntensity > 0 {
            // Sub-bass (kick drum body): 20–80 Hz
            let deepMinBin = max(1, Int(20.0 / hzPerBin))
            let deepMaxBin = min(halfLen - 1, Int(80.0 / hzPerBin))
            // Punch bass: 80–150 Hz
            let stdMinBin  = deepMaxBin
            let stdMaxBin  = min(halfLen - 1, Int(150.0 / hzPerBin))
            var deepSum: Float = 0
            if deepMaxBin > deepMinBin { for j in deepMinBin..<deepMaxBin { deepSum += fftActual[j] } }
            let deepAvg = deepSum / max(1, Float(deepMaxBin - deepMinBin))
            var stdSum: Float = 0
            if stdMaxBin > stdMinBin { for j in stdMinBin..<stdMaxBin { stdSum += fftActual[j] } }
            let stdAvg = stdSum / max(1, Float(stdMaxBin - stdMinBin))

            // Pass hardware timestamp so haptic fires exactly when DAC outputs the beat
            HapticManager.shared.updateHapticFeedback(
                deepBass: deepAvg,
                standardBass: stdAvg,
                intensity: hapticIntensity,
                bufferHostTime: outputHostTime,
                bufferFrameCount: count,
                sampleRate: sampleRate
            )
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

        DispatchQueue.main.async { self.amplitudes = newAmplitudes }
    }
}
