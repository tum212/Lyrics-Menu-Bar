import Foundation
import AVFoundation

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)

var receivedFrames = 0
var maxAmplitude: Float = 0.0

input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
    if let channelData = buf.floatChannelData?[0] {
        let frameLength = Int(buf.frameLength)
        let maxVal = (0..<frameLength).reduce(0.0 as Float) { max($0, abs(channelData[$1])) }
        maxAmplitude = max(maxAmplitude, maxVal)
        print("Tap: \(frameLength) frames, Max Amplitude this chunk: \(maxVal)")
    }
}

do {
    try engine.start()
    print("Started engine. Format: \(format)")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    print("Overall Max Amplitude: \(maxAmplitude)")
} catch {
    print("Error: \(error)")
}
