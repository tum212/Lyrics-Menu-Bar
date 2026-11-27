import Foundation

public enum AppCapabilities {
    /// True on macOS 14.2+ where CoreAudio Process Tap (CATapDescription) is available
    public static var supportsAudioTap: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }
}

public enum AppPerformance {
    /// Hardware & OS-aware default: Auto-ON for Intel Macs (x86_64), macOS 13, or Low Power Mode
    public static var defaultUltraLightMode: Bool {
        #if arch(x86_64)
        return true
        #else
        if #available(macOS 14.2, *) {
            return ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return true
        #endif
    }

    /// Live runtime Ultra-Light Mode flag (user toggleable in Settings)
    public static var isUltraLightMode: Bool {
        if UserDefaults.standard.object(forKey: AppSettingKey.ultraLightMode) != nil {
            return UserDefaults.standard.bool(forKey: AppSettingKey.ultraLightMode)
        }
        return defaultUltraLightMode
    }
}

public enum AppSettingKey {
    // Performance
    public static let ultraLightMode = "ultraLightMode"

    // Lyrics & Focus
    public static let lyricsFocusMode = "lyricsFocusMode"
    public static let lyricsMaxWidth = "lyricsMaxWidth"
    
    // Visibility & UI
    public static let showLyrics = "showLyrics"
    public static let showAlbumArt = "showAlbumArt"
    public static let audioFeaturesEnabled = "audioFeaturesEnabled"
    public static let specularEdgeEnabled = "specularEdgeEnabled"
    
    // Music Source
    public static let musicSourceMode = "musicSourceMode"
    
    // Audio & Waveform
    public static let waveformBars = "waveformBars"
    public static let lastWaveformBars = "lastWaveformBars"
    
    // Haptics
    public static let hapticEnabled = "hapticEnabled"
    public static let hapticIntensity = "hapticIntensity"
    public static let hapticActuatorType = "hapticActuatorType"
    
    // System
    public static let launchAtLogin = "launchAtLogin"
}

public enum AppDefaults {
    public static let defaultLyricsWidths: [Int] = [100, 150, 200, 260]
    
    public static func register() {
        let supportsTap = AppCapabilities.supportsAudioTap
        let defaultUltraLight = AppPerformance.defaultUltraLightMode

        UserDefaults.standard.register(defaults: [
            AppSettingKey.ultraLightMode: defaultUltraLight,
            AppSettingKey.lyricsFocusMode: true,
            AppSettingKey.lyricsMaxWidth: 200,
            AppSettingKey.showLyrics: true,
            AppSettingKey.showAlbumArt: true,
            AppSettingKey.audioFeaturesEnabled: supportsTap && !defaultUltraLight,
            AppSettingKey.specularEdgeEnabled: !defaultUltraLight,
            AppSettingKey.musicSourceMode: "Auto",
            AppSettingKey.waveformBars: (defaultUltraLight || !supportsTap) ? 0 : 14,
            AppSettingKey.hapticEnabled: false,
            AppSettingKey.hapticIntensity: 0,
            AppSettingKey.hapticActuatorType: 0
        ])

        // Ensure unsupported macOS 14.2+ audio tap stays off on macOS 13
        if !supportsTap {
            UserDefaults.standard.set(false, forKey: AppSettingKey.audioFeaturesEnabled)
            UserDefaults.standard.set(0, forKey: AppSettingKey.hapticIntensity)
        }

        // One-time auto-tuning for Intel / macOS 13 machines upgrading from older builds
        if defaultUltraLight && !UserDefaults.standard.bool(forKey: "ultraLightAutoTuned_b56") {
            UserDefaults.standard.set(true, forKey: AppSettingKey.ultraLightMode)
            UserDefaults.standard.set(false, forKey: AppSettingKey.specularEdgeEnabled)
            if !supportsTap {
                UserDefaults.standard.set(0, forKey: AppSettingKey.waveformBars)
            }
            UserDefaults.standard.set(true, forKey: "ultraLightAutoTuned_b56")
        }
    }
}
