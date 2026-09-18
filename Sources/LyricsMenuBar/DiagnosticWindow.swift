import SwiftUI
import AppKit

enum DiagnosticIssueType {
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
        case .notDefaultInput:
            return "System audio setup may be incorrect."
        case .silentAudio:
            return "We are not receiving any audio data.\n\nPlease ensure your System Audio Recording permissions are granted and audio is currently playing."
        }
    }

    
    private var resolveButtonText: String {
        switch issueType {
        case .notDefaultInput: return "Open Settings"
        case .silentAudio: return "Open Settings"
        }
    }
}

@MainActor
class DiagnosticWindowManager {
    static let shared = DiagnosticWindowManager()
    private var window: NSWindow?
    
    func showDiagnostic(issue: DiagnosticIssueType) {
        // Disabled completely per user request - no audio setup dialog
        closeWindow()
    }
    
    private func handleResolve(issue: DiagnosticIssueType) {
        switch issue {
        case .notDefaultInput:
            let url = URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane")
            NSWorkspace.shared.open(url)
        case .silentAudio:
            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
            NSWorkspace.shared.open(url)
        }
        closeWindow()
    }
    
    func closeWindow() {
        window?.close()
        window = nil
    }
}
