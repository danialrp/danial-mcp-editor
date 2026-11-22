import AVFoundation
import EditorCore
import Foundation

/// Where decoding has to begin for a frame to come out.
///
/// In open-GOP video (common in HEVC from cameras and screen recorders) the
/// few frames shown just before a keyframe are decoded after it and refer to
/// the group before. When AVFoundation starts decoding at a clip's first
/// frame and that frame is one of these, it starts at the following keyframe
/// and those frames never come out: 2 or 3 frames lost at the cut (found on
/// a test recording, phase 5). Decoding from the keyframe before
/// them gives every frame.
enum DecodeStart {
    /// The track time to start decoding from so that the frame shown at
    /// `time` decodes, when that is earlier than where AVFoundation would
    /// start; nil when AVFoundation's own start is fine.
    static func earlierStart(_ track: AVAssetTrack, segments: [AVAssetTrackSegment], at time: CMTime) -> CMTime? {
        leadIn(track, segments: segments, at: time)?.start
    }

    /// As `earlierStart`, with the keyframe the frame leads into: frames from
    /// `time` up to `keyframe` only come out when decoded in order from `start`.
    static func leadIn(_ track: AVAssetTrack, segments: [AVAssetTrackSegment], at time: CMTime) -> (start: CMTime, keyframe: CMTime)? {
        // Track time to media time, through the edit list.
        guard let seg = segments.first(where: { !$0.isEmpty && $0.timeMapping.target.containsTime(time) }),
              seg.timeMapping.source.duration == seg.timeMapping.target.duration else { return nil }
        let offset = seg.timeMapping.target.start - seg.timeMapping.source.start
        let media = time - offset
        guard let x = track.makeSampleCursor(presentationTimeStamp: media) else { return nil }
        if x.currentSampleSyncInfo.sampleIsFullSync.boolValue { return nil }
        // Walk back in decode order to the keyframe decoding would start at.
        guard let c = x.copy() as? AVSampleCursor else { return nil }
        var keyframe: CMTime?
        for _ in 0..<600 {
            guard c.stepInDecodeOrder(byCount: -1) == -1 else { return nil }
            guard c.currentSampleSyncInfo.sampleIsFullSync.boolValue else { continue }
            if c.presentationTimeStamp <= media {
                // A keyframe shown at or before the frame: a clean start.
                return keyframe.map { (c.presentationTimeStamp + offset, $0 + offset) }
            }
            // A keyframe decoded before the frame but shown after it: the
            // frame is one of its leading frames. Keep walking to the one before.
            if keyframe == nil { keyframe = c.presentationTimeStamp }
        }
        return nil
    }
}

/// Frames the compositor was asked for but got no picture for, so frame
/// capture knows to decode them another way. Keeps the last few times.
enum MissedFrames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var times: [Int64] = []

    static func record(_ t: CMTime) {
        let v = cm(time(t)).value
        lock.withLock {
            times.append(v)
            if times.count > 64 { times.removeFirst(times.count - 64) }
        }
    }

    /// True once for each recorded miss within half a 60 fps frame of `t`.
    static func take(_ t: CMTime) -> Bool {
        let v = cm(time(t)).value
        return lock.withLock {
            guard let i = times.lastIndex(where: { abs($0 - v) < Time.ticksPerSecond / 120 }) else { return false }
            times.remove(at: i)
            return true
        }
    }

    static func clear(_ t: CMTime) { while take(t) {} }
}
