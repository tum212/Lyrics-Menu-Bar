import Foundation
import SwiftUI

public enum AppEdition {
    /// True when running the Lite edition (macOS 13+ / ultra-low CPU & GPU footprint for older Macs)
    public static let isLite: Bool = {
        if let id = Bundle.main.bundleIdentifier?.lowercased(), id.contains("lite") {
            return true
        }
        if let name = Bundle.main.infoDictionary?["CFBundleName"] as? String, name.lowercased().contains("lite") {
            return true
        }
        return false
    }()
}

public enum AppSettingKey {
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
        let isLite = AppEdition.isLite
        UserDefaults.standard.register(defaults: [
            AppSettingKey.lyricsFocusMode: true,
            AppSettingKey.lyricsMaxWidth: 200,
            AppSettingKey.showLyrics: true,
            AppSettingKey.showAlbumArt: true,
            AppSettingKey.audioFeaturesEnabled: !isLite,
            AppSettingKey.specularEdgeEnabled: !isLite,
            AppSettingKey.musicSourceMode: "Auto",
            AppSettingKey.waveformBars: isLite ? 0 : 14,
            AppSettingKey.hapticEnabled: false,
            AppSettingKey.hapticIntensity: 0,
            AppSettingKey.hapticActuatorType: 0
        ])
        if isLite && !UserDefaults.standard.bool(forKey: "litePerformanceDefaultsApplied_b55") {
            UserDefaults.standard.set(false, forKey: AppSettingKey.audioFeaturesEnabled)
            UserDefaults.standard.set(0, forKey: AppSettingKey.waveformBars)
            UserDefaults.standard.set(false, forKey: AppSettingKey.specularEdgeEnabled)
            UserDefaults.standard.set(true, forKey: "litePerformanceDefaultsApplied_b55")
        }
    }
}
