import Foundation
import Accelerate
import CoreMedia
import CoreAudio
#if os(macOS)
import AppKit
import ScreenCaptureKit
#endif
import Combine

// MARK: - AudioAnalyzer
// Uses SCStream with capturesAudio=true and capturesVideo=false (macOS 14.2+) or
// the minimal video workaround for macOS 13, ensuring the "System Audio Recording"
// indicator (waveform icon) rather than the full "Screen Recording" indicator.

public final class AudioAnalyzer: NSObject, ObservableObject, @unchecked Sendable {
    @Published public var amplitudes: [CGFloat] = Array(repeating: 0.05, count: 14)

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

    #if os(macOS)
    private var stream: SCStream?
    #endif

    public override init() {
        super.init()
    }

    deinit {
        if let setup = cachedFFTSetup {
            vDSP_destroy_fftsetup(setup)
        }
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
        setupAudio()
    }

    public func stop() {
        guard isRunning else { return }
        #if os(macOS)
        stream?.stopCapture()
        stream = nil
        #endif
        isRunning = false
        DispatchQueue.main.async {
            self.amplitudes = Array(repeating: 0.0, count: self.bandCount)
        }
    }

    #if os(macOS)
    private var hasShownPermissionAlert = false

    @MainActor
    private func showPermissionAlert() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true

        let alert = NSAlert()
        alert.messageText = "System Audio Recording Access Required"
        alert.informativeText = "Lyrics Menu Bar requires System Audio Recording access to visualize your music. Please enable it in System Settings → Privacy & Security → Screen & System Audio Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    #endif

    private func setupAudio() {
        #if os(macOS)
        Task {
            do {
                // --- Build a filter that covers the whole display for audio purposes ---
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    print("⚠️ No display found")
                    return
                }

                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()

                // ── AUDIO ──────────────────────────────────────────────────────
                config.capturesAudio = true
                config.sampleRate    = 48000
                config.channelCount  = 2
                config.excludesCurrentProcessAudio = true   // no feedback loop

                // ── VIDEO — disabled as much as legally possible ───────────────
                // capturesVideo=false triggers the "System Audio Recording" (waveform)
                // indicator instead of the full "Screen Recording" indicator on macOS 14.2+.
                // We use KVC setValue because the Swift header in older SDKs may not expose it.
                if config.responds(to: Selector(("setCapturesVideo:"))) {
                    config.setValue(false, forKey: "capturesVideo")
                } else {
                    // Fallback for macOS 13: request 2×2 pixels at 1 fps to minimise
                    // video overhead; indicator will still say "Screen Recording" but
                    // the waveform capture works.
                    config.width  = 2
                    config.height = 2
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                }

                let newStream = SCStream(filter: filter, configuration: config, delegate: nil)

                // Only add audio output — never add a video output handler.
                try newStream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: .global(qos: .userInteractive)
                )
                try await newStream.startCapture()

                self.stream    = newStream
                self.isRunning = true
                print("✅ System Audio capture started (capturesVideo=false on macOS 14.2+)")

            } catch {
                print("⚠️ SCStream error: \(error)")
                DispatchQueue.main.async { self.showPermissionAlert() }
            }
        }
        #endif
    }

    // MARK: - Sliding-window FFT

    private let fftSize = 4096
    private var circularBuffer: [Float] = Array(repeating: 0, count: 4096)
    private var circularIndex: Int = 0
    private var lastPrintTime = Date()

    private func process(floatData: UnsafeBufferPointer<Float>, count: Int) {
        let halfLen = fftSize / 2

        if Date().timeIntervalSince(lastPrintTime) > 1.0 {
            var maxVal: Float = 0
            vDSP_maxv(floatData.baseAddress!, 1, &maxVal, vDSP_Length(count))
            print("🔊 Tap running. FrameLength: \(count), Max Amplitude: \(maxVal)")
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
        let sampleRate: Float = 48000
        let minHz: Float = 60,  maxHz: Float = 16000
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
            let span  = max(1, Int(Float(centerBin) * 0.15))
            let lo    = max(1, centerBin - span / 2)
            let hi    = min(halfLen - 1, lo + span)
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
            let stdMinBin  = deepMaxBin
            let stdMaxBin  = min(halfLen - 1, Int(120.0 / hzPerBin))
            var deepSum: Float = 0
            if deepMaxBin > deepMinBin { for j in deepMinBin..<deepMaxBin { deepSum += fftActual[j] } }
            let deepAvg = deepSum / max(1, Float(deepMaxBin - deepMinBin))
            var stdSum: Float = 0
            if stdMaxBin > stdMinBin { for j in stdMinBin..<stdMaxBin { stdSum += fftActual[j] } }
            let stdAvg  = stdSum / max(1, Float(stdMaxBin - stdMinBin))
            bassPeak = max(bassPeak * 0.92, max(deepAvg, stdAvg))
            let deepNorm = min(1.0, deepAvg / max(bassPeak, 0.0001))
            let stdNorm  = min(1.0, stdAvg  / max(bassPeak, 0.0001))
            DispatchQueue.main.async {
                HapticManager.shared.updateHapticFeedback(deepBass: deepNorm, standardBass: stdNorm)
            }
        }

        // Per-band auto-gain + spectrum smoothing
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

        // Silence detection
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

// MARK: - SCStreamOutput

#if os(macOS)
extension AudioAnalyzer: SCStreamOutput {
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Pull PCM data without any intermediate heap allocation
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        // Get format info
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }

        let isFloat       = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard isFloat else { return }   // We always expect Float32 from SCStream

        let numFrames   = CMSampleBufferGetNumSamples(sampleBuffer)
        let numChannels = Int(asbd.mChannelsPerFrame)
        guard numFrames > 0 else { return }

        // Use the AudioBufferList path to get a pointer into the existing CMBlockBuffer memory
        var abList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        // Read left-channel (or only channel) samples
        withUnsafePointer(to: abList.mBuffers) { bufPtr in
            let buf = bufPtr.pointee
            guard let rawPtr = buf.mData else { return }
            let floatPtr = rawPtr.assumingMemoryBound(to: Float.self)

            if isNonInterleaved {
                // Buffer contains only this channel's samples consecutively
                let samples = UnsafeBufferPointer(start: floatPtr, count: numFrames)
                process(floatData: samples, count: numFrames)
            } else {
                // Interleaved: stride = numChannels
                // Grab left channel into a temporary array
                var mono = [Float](repeating: 0, count: numFrames)
                for i in 0..<numFrames { mono[i] = floatPtr[i * numChannels] }
                mono.withUnsafeBufferPointer { process(floatData: $0, count: numFrames) }
            }
        }
    }
}
#endif
