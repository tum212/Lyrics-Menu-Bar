import Foundation
import CoreAudio

var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var dataSize: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
var ids = [AudioDeviceID](repeating: 0, count: count)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids)

for id in ids {
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var name: Unmanaged<CFString>?
    var nameAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
       let cfName = name?.takeRetainedValue() {
        print("Device \(id): \(cfName)")
    }
}
