import SwiftUI
import AppKit

enum DiagnosticIssueType {
    case missingBlackHole
    case notDefaultInput
    case silentAudio
}

struct DiagnosticView: View {
    let issueType: DiagnosticIssueType
    var onResolve: (() -> Void)?
    var onOptOut: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.cyan)
                .padding(.top, 20)
            
            Text("Audio Setup Required")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            
            Text(descriptionText)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .fixedSize(horizontal: false, vertical: true)
            
            VStack(spacing: 12) {
                Button(action: {
                    onResolve?()
                }) {
                    Text(resolveButtonText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.cyan)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: {
                    onOptOut?()
                }) {
                    Text("Disable Audio Features (Lyrics Only)")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .frame(width: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var descriptionText: String {
        switch issueType {
        case .missingBlackHole:
            return "We couldn't find BlackHole 2ch on your Mac.\n\nTo enable live waveforms and haptic feedback, you need to install the BlackHole virtual audio driver."
        case .notDefaultInput:
            return "BlackHole 2ch is installed, but it's not set as your Default Input device.\n\nPlease open Sound Settings and select BlackHole 2ch as your Input to allow the app to analyze the audio."
        case .silentAudio:
            return "We are not receiving any audio data.\n\nMake sure you have created a Multi-Output Device containing both BlackHole 2ch and your Speakers, and that it is selected as your current Sound Output."
        }
    }
    
    private var resolveButtonText: String {
        switch issueType {
        case .missingBlackHole: return "Download BlackHole"
        case .notDefaultInput: return "Open Sound Settings"
        case .silentAudio: return "Open Audio MIDI Setup"
        }
    }
}

@MainActor
class DiagnosticWindowManager {
    static let shared = DiagnosticWindowManager()
    private var window: NSWindow?
    
    func showDiagnostic(issue: DiagnosticIssueType) {
        DispatchQueue.main.async {
            if self.window != nil { return }
            
            let view = DiagnosticView(issueType: issue) {
                self.handleResolve(issue: issue)
            } onOptOut: {
                UserDefaults.standard.set(false, forKey: "audioFeaturesEnabled")
                NotificationCenter.default.post(name: Notification.Name("AudioFeaturesDisabled"), object: nil)
                self.closeWindow()
            }
            
            let hostingController = NSHostingController(rootView: view)
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.isMovableByWindowBackground = true
            newWindow.contentViewController = hostingController
            newWindow.center()
            newWindow.level = .floating
            
            self.window = newWindow
            
            NSApp.activate(ignoringOtherApps: true)
            newWindow.makeKeyAndOrderFront(nil)
        }
    }
    
    private func handleResolve(issue: DiagnosticIssueType) {
        switch issue {
        case .missingBlackHole:
            if let url = URL(string: "https://existential.audio/blackhole/") {
                NSWorkspace.shared.open(url)
            }
        case .notDefaultInput:
            let url = URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane")
            NSWorkspace.shared.open(url)
        case .silentAudio:
            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
            NSWorkspace.shared.open(url)
        }
        closeWindow()
    }
    
    private func closeWindow() {
        window?.close()
        window = nil
    }
}
