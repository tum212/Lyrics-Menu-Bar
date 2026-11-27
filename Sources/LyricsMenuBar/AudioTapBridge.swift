import AppKit
import AudioToolbox
import CLyricsCore
import CoreAudio
import CoreHaptics
import Foundation

// MARK: - CoreAudio Process Tap IOProc (Zero-Allocation Real-Time Audio Thread)
private func rustTapIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else { return noErr }
    let bridge = Unmanaged<AudioTapBridge>.fromOpaque(clientData).takeUnretainedValue()
    let bufferListPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    guard bufferListPtr.count > 0 else { return noErr }

    bridge.forwardPCMToRust(
        bufferListPtr: bufferListPtr,
        outputHostTime: inOutputTime.pointee.mHostTime
    )
    return noErr
}

private func onRustHapticFallback(_ ctx: UnsafeMutableRawPointer?, _ delay: Double, _ isDeep: Bool, _ intensity: Int32) {
    guard let ctx else { return }
    let bridge = Unmanaged<AudioTapBridge>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            bridge.fireCHHapticFallback(delay: delay, isDeep: isDeep, intensity: intensity)
        }
    }
}

// MARK: - Thin CoreAudio Tap + CHHaptic Fallback Bridge
@MainActor
public final class AudioTapBridge: NSObject {
    public static let shared = AudioTapBridge()

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    public private(set) var isRunning: Bool = false

    // Accessed on RT audio thread safely via nonisolated(unsafe) scalar copies
    nonisolated(unsafe) private var sampleRate: Float = 44100.0
    nonisolated(unsafe) private var hapticIntensity: Int32 = 0
    nonisolated(unsafe) private var audioHandle: OpaquePointer?
    nonisolated(unsafe) private var hapticsHandle: OpaquePointer?

    // Optional CHHapticEngine fallback when no Force Touch MTActuator exists
    private var fallbackEngine: CHHapticEngine?
    private var observers: [NSObjectProtocol] = []
    private var currentTargetBundleID: String = "com.spotify.client"
    private var hasShownAlert = false

    private override init() {
        super.init()
        let engine = LyricsCoreEngine.shared
        self.audioHandle = engine.audioHandle
        self.hapticsHandle = engine.hapticsHandle
        self.hapticIntensity = Int32(UserDefaults.standard.integer(forKey: AppSettingKey.hapticIntensity))

        guard AppCapabilities.supportsAudioTap else { return }

        prepareFallbackCHHapticEngine()

        let obs1 = NotificationCenter.default.addObserver(
            forName: Notification.Name("ActiveMusicSourceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bid = notif.userInfo?["bundleID"] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let bid { self?.retarget(bundleID: bid) }
                }
            }
        }
        observers.append(obs1)

        let obs2 = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.hapticIntensity = Int32(UserDefaults.standard.integer(forKey: AppSettingKey.hapticIntensity))
                }
            }
        }
        observers.append(obs2)
    }

    private func prepareFallbackCHHapticEngine() {
        let hasMT = lyrics_core_haptics_has_multitouch(LyricsCoreEngine.shared.hapticsHandle)
        guard !hasMT, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        if let eng = try? CHHapticEngine() {
            try? eng.start()
            self.fallbackEngine = eng
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            lyrics_core_haptics_set_fallback(
                LyricsCoreEngine.shared.hapticsHandle,
                onRustHapticFallback,
                selfPtr
            )
        }
    }

    fileprivate func fireCHHapticFallback(delay: Double, isDeep: Bool, intensity: Int32) {
        guard let eng = fallbackEngine else {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            return
        }
        let iv: Float = intensity == 3 ? 1.0 : (intensity == 2 ? 0.8 : 0.6)
        let sv: Float = isDeep ? 1.0 : 0.75
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: iv),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sv)
            ],
            relativeTime: 0
        )
        if let pattern = try? CHHapticPattern(events: [event], parameters: []),
           let player = try? eng.makePlayer(with: pattern) {
            try? player.start(atTime: eng.currentTime + max(0.0, delay))
        }
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

    public func start() {
        guard AppCapabilities.supportsAudioTap else { return }
        guard !isRunning else { return }
        guard UserDefaults.standard.bool(forKey: AppSettingKey.audioFeaturesEnabled) else { return }
        setupCoreAudioTap()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let validIOProcID = ioProcID, aggregateDeviceID != 0 {
            _ = AudioDeviceStop(aggregateDeviceID, validIOProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, validIOProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            ioProcID = nil
            aggregateDeviceID = 0
        }
        if tapID != 0 {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = 0
        }
        if let a = audioHandle {
            lyrics_core_audio_reset(a)
        }
    }

    nonisolated fileprivate func forwardPCMToRust(
        bufferListPtr: UnsafeMutableAudioBufferListPointer,
        outputHostTime: UInt64
    ) {
        guard let aHandle = audioHandle else { return }
        if bufferListPtr.count >= 2 {
            guard let lPtr = bufferListPtr[0].mData?.assumingMemoryBound(to: Float32.self),
                  let rPtr = bufferListPtr[1].mData?.assumingMemoryBound(to: Float32.self) else { return }
            let frames = Int(bufferListPtr[0].mDataByteSize) / MemoryLayout<Float32>.size
            guard frames > 0 else { return }
            lyrics_core_audio_process_pcm(
                aHandle, lPtr, rPtr, frames, 2, sampleRate, outputHostTime, hapticIntensity, hapticsHandle
            )
        } else if bufferListPtr[0].mNumberChannels == 2 {
            guard let data = bufferListPtr[0].mData?.assumingMemoryBound(to: Float32.self) else { return }
            let totalFloats = Int(bufferListPtr[0].mDataByteSize) / MemoryLayout<Float32>.size
            guard totalFloats >= 2 else { return }
            lyrics_core_audio_process_pcm(
                aHandle, data, nil, totalFloats, 2, sampleRate, outputHostTime, hapticIntensity, hapticsHandle
            )
        } else {
            guard let data = bufferListPtr[0].mData?.assumingMemoryBound(to: Float32.self) else { return }
            let frames = Int(bufferListPtr[0].mDataByteSize) / MemoryLayout<Float32>.size
            guard frames > 0 else { return }
            lyrics_core_audio_process_pcm(
                aHandle, data, nil, frames, 1, sampleRate, outputHostTime, hapticIntensity, hapticsHandle
            )
        }
    }

    private func showPermissionAlert() {
        guard !hasShownAlert else { return }
        hasShownAlert = true
        let alert = NSAlert()
        alert.messageText = "System Audio Recording Access Required"
        alert.informativeText = "Lyrics Menu Bar needs access to capture system audio for the waveform visualizer. Please enable it in System Settings → Privacy & Security → System Audio Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudioRecording") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setupCoreAudioTap() {
        guard #available(macOS 14.2, *) else { return }

        var targetBundleID = currentTargetBundleID
        let mode = UserDefaults.standard.string(forKey: AppSettingKey.musicSourceMode) ?? "Auto"
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
        guard let targetApp = targetApps.first else { return }
        currentTargetBundleID = targetBundleID

        var pid: pid_t = pid_t(targetApp.processIdentifier)
        let pidSize = UInt32(MemoryLayout<pid_t>.size)
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
        guard status == noErr, processID != 0 else { return }

        let desc = CATapDescription(stereoMixdownOfProcesses: [processID])
        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard tapStatus == noErr, newTapID != 0 else {
            showPermissionAlert()
            return
        }
        self.tapID = newTapID

        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(newTapID, &uidAddress, 0, nil, &uidSize, uidPtr)
        }
        guard uidStatus == noErr else {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = 0
            return
        }

        let aggregateDict: [String: Any] = [
            "name": "Spoticat Tap Aggregate",
            "uid": UUID().uuidString,
            "private": 1,
            "taps": [["uid": uid]]
        ]

        var aggregateID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = 0
            return
        }
        self.aggregateDeviceID = aggregateID

        var nominalSR: Float64 = 44100.0
        var srSize = UInt32(MemoryLayout<Float64>.size)
        var srAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(aggregateID, &srAddress, 0, nil, &srSize, &nominalSR) == noErr, nominalSR > 8000 {
            self.sampleRate = Float(nominalSR)
        }

        let clientData = Unmanaged.passUnretained(self).toOpaque()
        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(aggregateID, rustTapIOProc, clientData, &newIOProcID)
        guard ioStatus == noErr, let validIOProcID = newIOProcID else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            self.aggregateDeviceID = 0
            self.tapID = 0
            return
        }
        self.ioProcID = validIOProcID

        let startStatus = AudioDeviceStart(aggregateID, validIOProcID)
        if startStatus == noErr {
            self.isRunning = true
        } else {
            _ = AudioDeviceDestroyIOProcID(aggregateID, validIOProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            self.ioProcID = nil
            self.aggregateDeviceID = 0
            self.tapID = 0
        }
    }
}
