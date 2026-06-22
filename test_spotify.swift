import Foundation

let script = """
tell application "Spotify"
    if it is running then
        set trackName to name of current track
        return trackName
    else
        return "stopped"
    end if
end tell
"""

var error: NSDictionary?
if let appleScript = NSAppleScript(source: script) {
    let output = appleScript.executeAndReturnError(&error)
    if let result = output.stringValue {
        print("Success: \(result)")
    } else {
        print("AppleScript returned nil. Error: \(String(describing: error))")
    }
} else {
    print("Failed to compile script")
}
