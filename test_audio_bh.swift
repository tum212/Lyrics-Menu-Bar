import Foundation
import AVFoundation

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)

var receivedFrames = 0
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
    receivedFrames += Int(buf.frameLength)
    print("Received frames: \(receivedFrames)")
}

do {
    try engine.start()
    print("Started engine. Format: \(format)")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    print("Total frames: \(receivedFrames)")
} catch {
    print("Error: \(error)")
}
