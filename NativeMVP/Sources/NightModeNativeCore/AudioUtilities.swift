import AudioToolbox
import CoreAudio
import Foundation

public func allocateAudioBufferList(maximumBuffers: Int) -> (
    rawPointer: UnsafeMutableRawPointer,
    bufferList: UnsafeMutableAudioBufferListPointer
) {
    let size = MemoryLayout<AudioBufferList>.size
        + max(0, maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
    let rawPointer = UnsafeMutableRawPointer.allocate(
        byteCount: size,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    let pointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
    pointer.pointee.mNumberBuffers = UInt32(maximumBuffers)
    return (rawPointer, UnsafeMutableAudioBufferListPointer(pointer))
}

public func makeCanonicalFloatFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}
