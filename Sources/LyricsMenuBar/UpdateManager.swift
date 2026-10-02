import Foundation
import AppKit
import Combine

public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, releaseNotes: String, downloadUrl: URL)
    case downloading(progress: Double)
    case installing
    case failed(error: String)

    public static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate), (.installing, .installing):
            return true
        case (.updateAvailable(let v1, _, _), .updateAvailable(let v2, _, _)):
            return v1 == v2
        case (.downloading(let p1), .downloading(let p2)):
            return abs(p1 - p2) < 0.001
        case (.failed(let e1), .failed(let e2)):
            return e1 == e2
        default:
            return false
        }
    }
}

@MainActor
public final class UpdateManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = UpdateManager()

    @Published public private(set) var state: UpdateState = .idle
    @Published public var showUpdateModal: Bool = false
    @Published public private(set) var lastCheckDate: Date?

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0"
    }

    public var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    public var hasUpdate: Bool {
        if case .updateAvailable = state { return true }
        return false
    }

    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private let targetDmgPath = "/tmp/LyricsMenuBarUpdate.dmg"

    private override init() {
        super.init()
        // Auto check updates 3 seconds after launch
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await checkForUpdates(manual: false)
        }
    }

    public static func isVersion(_ remote: String, greaterThan local: String) -> Bool {
        let remoteParts = remote.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").compactMap { Int($0) }
        let localParts = local.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").compactMap { Int($0) }
        let maxCount = max(remoteParts.count, localParts.count)
        for i in 0..<maxCount {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    public func checkForUpdates(manual: Bool = false) async {
        state = .checking

        // 1. Fetch remote_config from Git
        let config = await RemoteConfigManager.shared.fetchRemoteConfig()
        lastCheckDate = Date()

        if let config = config, let downloadUrlStr = config.downloadUrl, let downloadUrl = URL(string: downloadUrlStr) {
            let isNewerVersion = Self.isVersion(config.version, greaterThan: currentVersion)
            let isNewerBuild = config.build > currentBuild && config.version == currentVersion

            if isNewerVersion || isNewerBuild {
                let notes = config.releaseNotes ?? "A new update for Lyrics Menu Bar is ready."
                state = .updateAvailable(version: config.version, releaseNotes: notes, downloadUrl: downloadUrl)
                showUpdateModal = true
                return
            }
        }

        // 2. Fallback to GitHub Releases API if remote config wasn't newer
        if let release = await fetchLatestGitHubRelease() {
            let releaseTag = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            if Self.isVersion(releaseTag, greaterThan: currentVersion), let assetUrl = release.dmgDownloadUrl {
                state = .updateAvailable(version: releaseTag, releaseNotes: release.body, downloadUrl: assetUrl)
                showUpdateModal = true
                return
            }
        }

        // Already up to date
        state = .upToDate
        if manual {
            showUpToDateAlert()
        }
    }

    public func startDownloadAndInstall() {
        guard case .updateAvailable(_, _, let downloadUrl) = state else { return }

        state = .downloading(progress: 0.0)
        let config = URLSessionConfiguration.default
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
        downloadTask = downloadSession?.downloadTask(with: downloadUrl)
        downloadTask?.resume()
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession = nil
        state = .idle
        showUpdateModal = false
    }

    // MARK: - URLSessionDownloadDelegate

    public nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        Task { @MainActor in
            self.state = .downloading(progress: progress)
        }
    }

    public nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: self.targetDmgPath) {
                try fileManager.removeItem(atPath: self.targetDmgPath)
            }
            try fileManager.moveItem(at: location, to: URL(fileURLWithPath: self.targetDmgPath))

            Task { @MainActor in
                self.installDownloadedUpdate()
            }
        } catch {
            Task { @MainActor in
                self.state = .failed(error: "Failed to save update file: \(error.localizedDescription)")
            }
        }
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            Task { @MainActor in
                self.state = .failed(error: error.localizedDescription)
            }
        }
    }

    // MARK: - Installation & Relaunch

    private func installDownloadedUpdate() {
        state = .installing

        let currentAppPath = Bundle.main.bundlePath
        let targetAppPath = currentAppPath.hasPrefix("/Applications") ? currentAppPath : "/Applications/Lyrics Menu Bar.app"
        let scriptPath = "/tmp/update_lyricsmenubar.sh"
        let mountPoint = "/tmp/LyricsMenuBarMount"

        let scriptContent = """
        #!/bin/bash
        sleep 1.2
        hdiutil detach "\(mountPoint)" -force 2>/dev/null || true
        rm -rf "\(mountPoint)"
        mkdir -p "\(mountPoint)"

        hdiutil attach "\(targetDmgPath)" -nobrowse -mountpoint "\(mountPoint)" -quiet
        sleep 0.6

        if [ -d "\(mountPoint)/Lyrics Menu Bar.app" ]; then
            rm -rf "\(targetAppPath)"
            cp -R "\(mountPoint)/Lyrics Menu Bar.app" "/Applications/"
            xattr -cr "\(targetAppPath)" 2>/dev/null || true
        fi

        hdiutil detach "\(mountPoint)" -quiet 2>/dev/null || true
        rm -rf "\(mountPoint)" "\(targetDmgPath)" "\(scriptPath)"
        open -a "\(targetAppPath)"
        """

        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", scriptPath]
            try chmod.run()
            chmod.waitUntilExit()

            let updaterProcess = Process()
            updaterProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            updaterProcess.arguments = ["-c", "nohup \(scriptPath) >/dev/null 2>&1 &"]
            try updaterProcess.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        } catch {
            state = .failed(error: "Installation launcher error: \(error.localizedDescription)")
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "Lyrics Menu Bar is Up to Date"
        alert.informativeText = "You are running the latest version (v\(currentVersion))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - GitHub Releases Fallback Helper

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String
        let body: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, assets
        }

        var dmgDownloadUrl: URL? {
            if let asset = assets.first(where: { $0.name.hasSuffix(".dmg") }) {
                return URL(string: asset.browserDownloadUrl)
            }
            return nil
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    private func fetchLatestGitHubRelease() async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/tum212/Lyrics-Menu-Bar/releases/latest") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("LyricsMenuBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            return nil
        }
    }
}
