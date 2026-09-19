import Foundation
import SwiftUI

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
        UserDefaults.standard.register(defaults: [
            AppSettingKey.lyricsFocusMode: true,
            AppSettingKey.lyricsMaxWidth: 200,
            AppSettingKey.showLyrics: true,
            AppSettingKey.showAlbumArt: true,
            AppSettingKey.audioFeaturesEnabled: true,
            AppSettingKey.specularEdgeEnabled: true,
            AppSettingKey.musicSourceMode: "Auto",
            AppSettingKey.waveformBars: 14,
            AppSettingKey.hapticEnabled: false,
            AppSettingKey.hapticIntensity: 0,
            AppSettingKey.hapticActuatorType: 0
        ])
    }
}
