import AppKit
import AudioToolbox
import CLyricsCore
import CoreAudio
import CoreHaptics
import Darwin
import Foundation

// MARK: - Lock-Protected Real-Time Audio State (macOS 13+ Compatible)

private final class AudioRTState: @unchecked Sendable {
    private var lock = os_unfair_lock()
    let audioHandle: OpaquePointer
    let hapticsHandle: OpaquePointer
    private var _sampleRate: Float = 44100.0
    private var _hapticIntensity: Int32 = 0
    private var _isFloatPCM: Bool = true
    private var _isActive: Bool = false

    init(audioHandle: OpaquePointer, hapticsHandle: OpaquePointer) {
        self.audioHandle = audioHandle
        self.hapticsHandle = hapticsHandle
    }

    func setSampleRate(_ sr: Float) {
        os_unfair_lock_lock(&lock)
        _sampleRate = sr
        os_unfair_lock_unlock(&lock)
    }

    func setHapticIntensity(_ intensity: Int32) {
        os_unfair_lock_lock(&lock)
        _hapticIntensity = intensity
        os_unfair_lock_unlock(&lock)
    }

    func setStreamConfig(isFloatPCM: Bool, isActive: Bool) {
        os_unfair_lock_lock(&lock)
        _isFloatPCM = isFloatPCM
        _isActive = isActive
        os_unfair_lock_unlock(&lock)
    }

    func setActive(_ active: Bool) {
        os_unfair_lock_lock(&lock)
        _isActive = active
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> (sampleRate: Float, hapticIntensity: Int32, isFloatPCM: Bool, isActive: Bool) {
        os_unfair_lock_lock(&lock)
        let res = (_sampleRate, _hapticIntensity, _isFloatPCM, _isActive)
        os_unfair_lock_unlock(&lock)
        return res
    }
}

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
    let rtState = Unmanaged<AudioRTState>.fromOpaque(clientData).takeUnretainedValue()
    let snap = rtState.snapshot()
    guard snap.isActive, snap.isFloatPCM else { return noErr }

    let bufferListPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    guard bufferListPtr.count > 0 else { return noErr }

    // Resolve reliable Mach host time (inOutputTime can be 0 on tap-only aggregate devices!)
    let hostTime: UInt64
    if inOutputTime.pointee.mHostTime != 0 {
        hostTime = inOutputTime.pointee.mHostTime
    } else if inInputTime.pointee.mHostTime != 0 {
        hostTime = inInputTime.pointee.mHostTime
    } else if inNow.pointee.mHostTime != 0 {
        hostTime = inNow.pointee.mHostTime
    } else {
        hostTime = mach_absolute_time()
    }

    let floatSize = MemoryLayout<Float32>.size
    if bufferListPtr.count >= 2 {
        // Non-interleaved (planar) stereo or multichannel
        guard let lPtr = bufferListPtr[0].mData?.assumingMemoryBound(to: Float32.self),
              let rPtr = bufferListPtr[1].mData?.assumingMemoryBound(to: Float32.self) else { return noErr }
        let framesL = Int(bufferListPtr[0].mDataByteSize) / floatSize
        let framesR = Int(bufferListPtr[1].mDataByteSize) / floatSize
        let frames = min(framesL, framesR)
        guard frames > 0 else { return noErr }
        lyrics_core_audio_process_pcm(
            rtState.audioHandle,
            lPtr,
            rPtr,
            frames,
            2,
            snap.sampleRate,
            hostTime,
            snap.hapticIntensity,
            rtState.hapticsHandle
        )
    } else {
        let buf = bufferListPtr[0]
        guard let data = buf.mData?.assumingMemoryBound(to: Float32.self) else { return noErr }
        let totalFloats = Int(buf.mDataByteSize) / floatSize
        let channels = max(1, min(16, Int(buf.mNumberChannels)))
        guard totalFloats >= channels else { return noErr }
        lyrics_core_audio_process_pcm(
            rtState.audioHandle,
            data,
            nil,
            totalFloats,
            channels,
            snap.sampleRate,
            hostTime,
            snap.hapticIntensity,
            rtState.hapticsHandle
        )
    }

    return noErr
}

private func onRustHapticFallback(_ ctx: UnsafeMutableRawPointer?, _ delay: Double, _ isDeep: Bool, _ intensity: Int32) {
    guard let ctx else { return }
    let bridge = Unmanaged<AudioTapBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.scheduleCHHapticFallback(delay: delay, isDeep: isDeep, intensity: intensity)
}

// MARK: - BSD Process Tree & CoreAudio Process Discovery Helpers

private enum AudioProcessInspector {
    /// Returns the parent PID of `pid` using BSD `proc_pidinfo` (zero shell spawns).
    static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if result == size {
            return pid_t(info.pbi_ppid)
        }
        return 0
    }

    /// Walks up to 6 ancestors to check if `pid` descends from any PID in `rootPIDs`.
    static func isDescendant(_ pid: pid_t, ofAny rootPIDs: Set<pid_t>) -> Bool {
        if rootPIDs.contains(pid) { return true }
        var current = pid
        for _ in 0..<6 {
            let parent = parentPID(of: current)
            if parent <= 1 || parent == current { break }
            if rootPIDs.contains(parent) { return true }
            current = parent
        }
        return false
    }

    /// Reads a CoreAudio CFString property safely without leaking the +1 retained CFString.
    static func readCFStringProperty(objectID: AudioObjectID, address: inout AudioObjectPropertyAddress) -> String? {
        var rawPtr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &rawPtr) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let retained = rawPtr else { return nil }
        return retained.takeRetainedValue() as String
    }

    /// Lists all CoreAudio audio process object IDs currently registered with the HAL.
    @available(macOS 14.2, *)
    static func allAudioProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &byteSize) == noErr,
              byteSize >= MemoryLayout<AudioObjectID>.size else {
            return []
        }
        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        let status = objects.withUnsafeMutableBufferPointer { buf in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &byteSize, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return objects.filter { $0 != 0 }
    }

    @available(macOS 14.2, *)
    static func pid(forProcessObject objID: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, &pid) == noErr else { return 0 }
        return pid
    }

    @available(macOS 14.2, *)
    static func bundleID(forProcessObject objID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return readCFStringProperty(objectID: objID, address: &addr)
    }

    @available(macOS 14.2, *)
    static func isRunningOutput(processObject objID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Resolves ALL CoreAudio process objects belonging to `bundleID` (including Electron/Chromium/Safari helper subprocesses).
    @available(macOS 14.2, *)
    static func resolveProcessObjects(forBundleID bundleID: String) -> [AudioObjectID] {
        let descriptor = MusicSourceRegistry.shared.canonicalDescriptor(forBundleID: bundleID)
        let targetBundleIDs = Set(descriptor?.allBundleIDs ?? [bundleID])
        let helperPrefixes = descriptor?.audioHelperPrefixes ?? [bundleID]

        var rootPIDs = Set<pid_t>()
        for bid in targetBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) where !app.isTerminated {
                rootPIDs.insert(app.processIdentifier)
            }
        }

        let allObjects = allAudioProcessObjects()
        var matched = [AudioObjectID]()
        var seen = Set<AudioObjectID>()

        for objID in allObjects {
            let p = pid(forProcessObject: objID)
            let objBID = self.bundleID(forProcessObject: objID) ?? ""

            var isMatch = false
            if p > 0 && isDescendant(p, ofAny: rootPIDs) {
                isMatch = true
            } else if !objBID.isEmpty {
                if targetBundleIDs.contains(objBID) {
                    isMatch = true
                } else if helperPrefixes.contains(where: { objBID.hasPrefix($0) }) {
                    // For Safari WebKit GPU/WebContent helpers, only attach if Safari is running
                    if !rootPIDs.isEmpty {
                        isMatch = true
                    }
                }
            }

            if isMatch && seen.insert(objID).inserted {
                matched.append(objID)
            }
        }

        // Direct PID translation fallback (covers freshly started native apps)
        if matched.isEmpty {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            for rootPID in rootPIDs {
                var pidVal = rootPID
                var objID: AudioObjectID = 0
                var objSize = UInt32(MemoryLayout<AudioObjectID>.size)
                if AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addr,
                    UInt32(MemoryLayout<pid_t>.size),
                    &pidVal,
                    &objSize,
                    &objID
                ) == noErr, objID != 0, seen.insert(objID).inserted {
                    matched.append(objID)
                }
            }
        }

        return matched
    }

    /// Returns the executable path of `pid` using BSD `proc_pidpath` (zero shell spawns).
    static func executablePath(of pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return "" }
        return String(decoding: buf.prefix(Int(len)), as: UTF8.self)
    }

    /// Returns canonical bundle IDs of all apps/browsers currently outputting audio via CoreAudio (no tap permission needed).
    static func activeOutputBundleIDs() -> Set<String> {
        guard #available(macOS 14.2, *) else { return [] }
        let registry = MusicSourceRegistry.shared
        let allObjects = allAudioProcessObjects()
        var active = Set<String>()

        // Build map of running app PIDs -> canonical bundle ID for fast ancestor lookup
        var pidToCanonical = [pid_t: String]()
        var isSafariRunning = false
        for (desc, app) in registry.runningPlayers() {
            pidToCanonical[app.processIdentifier] = desc.id
            if desc.id == "com.apple.Safari" {
                isSafariRunning = true
            }
        }

        for objID in allObjects {
            guard isRunningOutput(processObject: objID) else { continue }
            var objBID = bundleID(forProcessObject: objID) ?? ""
            let p = pid(forProcessObject: objID)

            if objBID.isEmpty && p > 0 {
                objBID = NSRunningApplication(processIdentifier: p)?.bundleIdentifier ?? ""
            }
            if !objBID.isEmpty, let desc = registry.canonicalDescriptor(forBundleID: objBID) {
                active.insert(desc.id)
                continue
            }
            if p > 0 {
                if let direct = pidToCanonical[p] {
                    active.insert(direct)
                    continue
                }
                // Check XPC/WebKit helper executable path (Safari WebKit.GPU/WebContent has parent PID 1)
                let exePath = executablePath(of: p)
                if isSafariRunning && (exePath.contains("WebKit.GPU") || exePath.contains("WebKit.WebContent") || exePath.contains("Safari")) {
                    active.insert("com.apple.Safari")
                    continue
                }
                var cur = p
                for _ in 0..<6 {
                    let parent = parentPID(of: cur)
                    if parent <= 1 || parent == cur { break }
                    if let matched = pidToCanonical[parent] {
                        active.insert(matched)
                        break
                    }
                    cur = parent
                }
            }
            if !objBID.isEmpty {
                active.insert(objBID)
            }
        }
        return active
    }
}

// MARK: - Dedicated Serial CoreAudio Tap + CHHaptic Fallback Bridge

public final class AudioTapBridge: NSObject, @unchecked Sendable {
    @MainActor public static let shared = AudioTapBridge()

    private let halQueue = DispatchQueue(label: "com.lyricsmenubar.audiotap.hal", qos: .userInitiated)
    private let hapticQueue = DispatchQueue(label: "com.lyricsmenubar.haptics.fallback", qos: .userInteractive)
    private let rtState: AudioRTState

    // HAL-queue-owned resources (NEVER touched on main thread!)
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?
    private var aliveListenerBlock: AudioObjectPropertyListenerBlock?
    private var desiredRunning: Bool = false
    private var desiredBundleID: String = "com.spotify.client"
    private var activeBundleID: String = ""
    private var generation: UInt64 = 0
    private var retryWorkItem: DispatchWorkItem?
    private var retryAttempt: Int = 0
    private let retryDelays: [TimeInterval] = [0.45, 1.0, 2.0]

    // Main-actor-readable state
    @MainActor public private(set) var isRunning: Bool = false
    @MainActor private var currentTargetBundleID: String = "com.spotify.client"
    @MainActor private var hasShownAlert = false
    @MainActor private var observers: [NSObjectProtocol] = []

    // Haptic-queue-owned fallback CHHapticEngine (only created on Macs without Force Touch MTActuator)
    private var fallbackEngine: CHHapticEngine?
    private var fallbackEnginePrepared: Bool = false

    @MainActor
    private override init() {
        let engine = LyricsCoreEngine.shared
        self.rtState = AudioRTState(audioHandle: engine.audioHandle, hapticsHandle: engine.hapticsHandle)
        super.init()

        let initialIntensity = Int32(UserDefaults.standard.integer(forKey: AppSettingKey.hapticIntensity))
        rtState.setHapticIntensity(initialIntensity)

        guard AppCapabilities.supportsAudioTap else { return }

        // Register fallback callback ONLY if Force Touch MTActuator is unavailable
        let hasMT = lyrics_core_haptics_has_multitouch(engine.hapticsHandle)
        if !hasMT && CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            lyrics_core_haptics_set_fallback(engine.hapticsHandle, onRustHapticFallback, selfPtr)
        }

        let obs1 = NotificationCenter.default.addObserver(
            forName: Notification.Name("ActiveMusicSourceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bid = notif.userInfo?["bundleID"] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let bid, !bid.isEmpty {
                        self?.retarget(bundleID: bid)
                    }
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
                    let intensity = Int32(UserDefaults.standard.integer(forKey: AppSettingKey.hapticIntensity))
                    self?.rtState.setHapticIntensity(intensity)
                }
            }
        }
        observers.append(obs2)
    }

    /// Public, permission-free query of which bundle IDs are currently outputting audio via CoreAudio.
    public static func activeOutputAudioBundleIDs() -> Set<String> {
        AudioProcessInspector.activeOutputBundleIDs()
    }

    // MARK: - Lazy CHHapticEngine Fallback (High-QoS Serial Queue)

    fileprivate func scheduleCHHapticFallback(delay: Double, isDeep: Bool, intensity: Int32) {
        hapticQueue.async { [weak self] in
            guard let self else { return }
            if !self.fallbackEnginePrepared {
                self.fallbackEnginePrepared = true
                if let eng = try? CHHapticEngine() {
                    eng.stoppedHandler = { [weak self] _ in
                        guard let bridge = self else { return }
                        bridge.hapticQueue.async {
                            try? bridge.fallbackEngine?.start()
                        }
                    }
                    eng.resetHandler = { [weak self] in
                        guard let bridge = self else { return }
                        bridge.hapticQueue.async {
                            try? bridge.fallbackEngine?.start()
                        }
                    }
                    try? eng.start()
                    self.fallbackEngine = eng
                }
            }

            guard let eng = self.fallbackEngine else {
                DispatchQueue.main.async {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
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
            do {
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try eng.makePlayer(with: pattern)
                try player.start(atTime: eng.currentTime + max(0.0, delay))
            } catch {
                try? eng.start()
            }
        }
    }

    // MARK: - Public Lifecycle API (MainActor)

    @MainActor
    public func retarget(bundleID: String) {
        guard !bundleID.isEmpty, bundleID != currentTargetBundleID else { return }
        currentTargetBundleID = bundleID
        let shouldBeRunning = isRunning
        halQueue.async { [weak self] in
            guard let self else { return }
            self.desiredBundleID = bundleID
            if self.desiredRunning || shouldBeRunning {
                self.retryAttempt = 0
                self.generation &+= 1
                let gen = self.generation
                self.teardownHALResources()
                self.setupHALTapIfNeeded(expectedGen: gen)
            }
        }
    }

    @MainActor
    public func start() {
        guard AppCapabilities.supportsAudioTap else { return }
        guard UserDefaults.standard.bool(forKey: AppSettingKey.audioFeaturesEnabled) else { return }

        let target = resolvePreferredBundleIDOnMain()
        currentTargetBundleID = target

        halQueue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = true
            self.desiredBundleID = target
            if self.ioProcID != nil && self.activeBundleID == target {
                return
            }
            self.retryAttempt = 0
            self.generation &+= 1
            let gen = self.generation
            self.teardownHALResources()
            self.setupHALTapIfNeeded(expectedGen: gen)
        }
    }

    @MainActor
    public func stop() {
        self.isRunning = false
        halQueue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = false
            self.generation &+= 1
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.retryAttempt = 0
            self.teardownHALResources()
        }
    }

    @MainActor
    private func resolvePreferredBundleIDOnMain() -> String {
        let engineBundle = LyricsCoreEngine.shared.activeAudioBundleID
        if !engineBundle.isEmpty {
            return engineBundle
        }
        let sel = MusicSourceSelection(defaultsValue: UserDefaults.standard.string(forKey: AppSettingKey.musicSourceMode) ?? "Auto")
        switch sel {
        case .specific(let bid):
            return bid
        case .auto:
            return currentTargetBundleID.isEmpty ? "com.spotify.client" : currentTargetBundleID
        }
    }

    @MainActor
    private func showPermissionAlert() {
        guard !hasShownAlert else { return }
        hasShownAlert = true
        SettingsMenuController.beginModalPresentation()
        defer { SettingsMenuController.endModalPresentation() }
        let alert = NSAlert()
        alert.messageText = "System Audio Recording Access Required"
        alert.informativeText = "Lyrics Menu Bar needs System Audio Recording access for the real-time waveform visualizer and beat haptics. Please enable it in System Settings → Privacy & Security → System Audio Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudioRecording") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - CoreAudio HAL Operations (Strictly on `halQueue`)

    private func teardownHALResources() {
        rtState.setActive(false)
        retryWorkItem?.cancel()
        retryWorkItem = nil

        if aggregateDeviceID != 0 {
            if let srBlock = sampleRateListenerBlock {
                var srAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(aggregateDeviceID, &srAddr, halQueue, srBlock)
                sampleRateListenerBlock = nil
            }
            if let aliveBlock = aliveListenerBlock {
                var aliveAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsAlive,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(aggregateDeviceID, &aliveAddr, halQueue, aliveBlock)
                aliveListenerBlock = nil
            }
        }

        if let validIOProc = ioProcID {
            if aggregateDeviceID != 0 {
                _ = AudioDeviceStop(aggregateDeviceID, validIOProc)
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, validIOProc)
            }
            ioProcID = nil
        }

        if aggregateDeviceID != 0 {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }

        if tapID != 0 {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = 0
        }

        activeBundleID = ""
        lyrics_core_audio_reset(rtState.audioHandle)

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isRunning = false
            }
        }
    }

    private func scheduleRetry(expectedGen: UInt64) {
        guard desiredRunning, generation == expectedGen else { return }
        guard retryAttempt < retryDelays.count else { return }
        let delay = retryDelays[retryAttempt]
        retryAttempt += 1

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.desiredRunning, self.generation == expectedGen else { return }
            self.setupHALTapIfNeeded(expectedGen: expectedGen)
        }
        retryWorkItem?.cancel()
        retryWorkItem = work
        halQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setupHALTapIfNeeded(expectedGen: UInt64) {
        guard #available(macOS 14.2, *) else { return }
        guard desiredRunning, generation == expectedGen else { return }

        let targetBID = desiredBundleID
        let processObjects = AudioProcessInspector.resolveProcessObjects(forBundleID: targetBID)
        guard !processObjects.isEmpty else {
            // Audio process may not have registered an output stream yet — retry with bounded backoff
            scheduleRetry(expectedGen: expectedGen)
            return
        }

        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.name = "LyricsMenuBarTap-\(targetBID)"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.isExclusive = false

        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard tapStatus == noErr, newTapID != 0 else {
            if tapStatus != noErr {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.showPermissionAlert()
                    }
                }
            }
            return
        }
        self.tapID = newTapID

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let tapUID = AudioProcessInspector.readCFStringProperty(objectID: newTapID, address: &uidAddr),
              !tapUID.isEmpty else {
            teardownHALResources()
            return
        }

        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LyricsMenuBar Tap Aggregate",
            kAudioAggregateDeviceUIDKey: "com.lyricsmenubar.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregateID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != 0 else {
            teardownHALResources()
            scheduleRetry(expectedGen: expectedGen)
            return
        }
        self.aggregateDeviceID = aggregateID

        // Query stream format & nominal sample rate
        var isFloatPCM = true
        var streamFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(aggregateID, &fmtAddr, 0, nil, &fmtSize, &streamFormat) == noErr {
            isFloatPCM = (streamFormat.mFormatID == kAudioFormatLinearPCM)
                && ((streamFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
            if streamFormat.mSampleRate >= 8000 {
                rtState.setSampleRate(Float(streamFormat.mSampleRate))
            }
        }

        var nominalSR: Float64 = 44100.0
        var srSize = UInt32(MemoryLayout<Float64>.size)
        var srAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(aggregateID, &srAddr, 0, nil, &srSize, &nominalSR) == noErr, nominalSR >= 8000 {
            rtState.setSampleRate(Float(nominalSR))
        }

        // Listen for sample-rate changes (e.g. AirPods HFP 16 kHz <-> 48 kHz) & device teardown
        let srBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.aggregateDeviceID != 0 else { return }
            var sr: Float64 = 44100.0
            var sz = UInt32(MemoryLayout<Float64>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(self.aggregateDeviceID, &addr, 0, nil, &sz, &sr) == noErr, sr >= 8000 {
                self.rtState.setSampleRate(Float(sr))
            }
        }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &srAddr, halQueue, srBlock) == noErr {
            sampleRateListenerBlock = srBlock
        }

        var aliveAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.aggregateDeviceID != 0 else { return }
            var alive: UInt32 = 1
            var sz = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(self.aggregateDeviceID, &addr, 0, nil, &sz, &alive) == noErr, alive == 0 {
                self.generation &+= 1
                let g = self.generation
                self.teardownHALResources()
                self.retryAttempt = 0
                self.scheduleRetry(expectedGen: g)
            }
        }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &aliveAddr, halQueue, aliveBlock) == noErr {
            aliveListenerBlock = aliveBlock
        }

        let clientData = Unmanaged.passUnretained(rtState).toOpaque()
        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(aggregateID, rustTapIOProc, clientData, &newIOProcID)
        guard ioStatus == noErr, let validIOProcID = newIOProcID else {
            teardownHALResources()
            return
        }
        self.ioProcID = validIOProcID
        rtState.setStreamConfig(isFloatPCM: isFloatPCM, isActive: true)

        let startStatus = AudioDeviceStart(aggregateID, validIOProcID)
        if startStatus == noErr {
            self.activeBundleID = targetBID
            self.retryAttempt = 0
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.isRunning = true
                }
            }
        } else {
            teardownHALResources()
            scheduleRetry(expectedGen: expectedGen)
        }
    }
}
