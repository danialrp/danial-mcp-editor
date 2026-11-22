import AVFoundation
import Accelerate
import MediaToolbox

/// The audio mix can only lower a level (its volume stops at 1). To raise a
/// track, its volume ramps are scaled down by the track's largest gain and
/// this tap multiplies the track by that gain again, so every clip ends up at
/// exactly its own gain, above 0 dB included.
enum GainTap {
    private final class Box {
        let gain: Float
        var isFloat = true
        init(_ gain: Float) { self.gain = gain }
    }

    static func make(gain: Float) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(Box(gain)).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let box = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                box.isFloat = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.pointee.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let box = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard box.isFloat else { return }
                var g = box.gain
                for buf in UnsafeMutableAudioBufferListPointer(bufferList) {
                    guard let data = buf.mData else { continue }
                    let p = data.assumingMemoryBound(to: Float.self)
                    vDSP_vsmul(p, 1, &g, p, 1, vDSP_Length(Int(buf.mDataByteSize) / 4))
                }
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        return status == noErr ? tap : nil
    }
}
