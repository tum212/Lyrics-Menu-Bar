import Foundation
import Combine
import AppKit

public struct SpotifyTrack: Equatable {
    public var id: String
    public var name: String
    public var artist: String
    public var album: String
    public var artworkURL: String?
    public var duration: Double // in seconds
    
    public init(id: String, name: String, artist: String, album: String, artworkURL: String?, duration: Double) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
    }
}

public final class SpotifyService: ObservableObject, @unchecked Sendable {
    @Published public var currentTrack: SpotifyTrack?
    @Published public var isPlaying: Bool = false
    @Published public var playbackPosition: Double = 0.0
    @Published public var lastUpdateDate: Date = Date()
    
    private var timer: Timer?
    
    public init() {
        startPolling()
    }
    
    deinit {
        stopPolling()
    }
    
    public func startPolling() {
        // Poll every second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollSpotify()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        // Run immediately
        pollSpotify()
    }
    
    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
    
    private func pollSpotify() {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackId to id of current track
                set trackDuration to duration of current track
                try
                    set trackArtworkURL to artwork url of current track
                on error
                    set trackArtworkURL to ""
                end try
                set playerState to player state as string
                set playerPosition to player position
                
                return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackId & "|||" & trackDuration & "|||" & trackArtworkURL & "|||" & playerState & "|||" & playerPosition
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let output = appleScript.executeAndReturnError(&error)
            if let stringValue = output.stringValue {
                if stringValue == "NOT_RUNNING" {
                    DispatchQueue.main.async {
                        self.currentTrack = nil
                        self.isPlaying = false
                        self.playbackPosition = 0.0
                    }
                } else {
                    let components = stringValue.components(separatedBy: "|||")
                    if components.count >= 8 {
                        let name = components[0]
                        let artist = components[1]
                        let album = components[2]
                        let id = components[3]
                        // Spotify duration is typically in milliseconds
                        let duration = (Double(components[4]) ?? 0) / 1000.0
                        let artworkURL = components[5]
                        let state = components[6]
                        let position = Double(components[7]) ?? 0.0
                        
                        let track = SpotifyTrack(
                            id: id,
                            name: name,
                            artist: artist,
                            album: album,
                            artworkURL: artworkURL.isEmpty ? nil : artworkURL,
                            duration: duration
                        )
                        
                        DispatchQueue.main.async {
                            let newIsPlaying = (state == "playing")
                            let expectedPosition = self.isPlaying ? self.playbackPosition + Date().timeIntervalSince(self.lastUpdateDate) : self.playbackPosition
                            
                            if abs(expectedPosition - position) > 2.0 || self.currentTrack?.id != track.id || newIsPlaying != self.isPlaying {
                                self.playbackPosition = position
                                self.lastUpdateDate = Date()
                            }
                            
                            self.isPlaying = newIsPlaying
                            self.currentTrack = track
                        }
                    }
                }
            } else if error != nil {
                print("AppleScript Error: \(String(describing: error))")
            }
        }
    }
    
    public func playPause() {
        runCommand("playpause")
        isPlaying.toggle()
    }
    
    public func nextTrack() {
        runCommand("next track")
    }
    
    public func previousTrack() {
        runCommand("previous track")
    }
    
    private func runCommand(_ command: String) {
        let script = "tell application \"Spotify\" to \(command)"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }
}
