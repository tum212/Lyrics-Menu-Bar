import AppKit
import Foundation
import ServiceManagement

public enum LaunchAtLoginManager {
    public static var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                let status = SMAppService.mainApp.status
                return status == .enabled || status == .requiresApproval
            }
            return UserDefaults.standard.bool(forKey: AppSettingKey.launchAtLogin)
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        if SMAppService.mainApp.status != .enabled {
                            try SMAppService.mainApp.register()
                        }
                        if SMAppService.mainApp.status == .requiresApproval {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    } else {
                        if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                            try SMAppService.mainApp.unregister()
                        }
                    }
                    UserDefaults.standard.set(isEnabled, forKey: AppSettingKey.launchAtLogin)
                } catch {
                    logDebug("Error setting launch at login: \(error)")
                }
            } else {
                UserDefaults.standard.set(newValue, forKey: AppSettingKey.launchAtLogin)
            }
        }
    }
}
