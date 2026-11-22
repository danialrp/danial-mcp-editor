import AVFoundation
import Darwin
import QuartzCore

/// Test 1: plays a many-cut composition through the custom compositor and
/// records which frames arrive, when, and what it costs.
func runPlayback(source: URL, cuts: Int, speed: Double, seconds: Double, scale: Double) async throws {
    var cc = try await buildCutComposition(source: source, cuts: cuts, speed: speed)
    if scale != 1 {
        let s = cc.videoComposition.renderSize
        cc.videoComposition.renderSize = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
    }
    print("render size: \(cc.videoComposition.renderSize)")
    print(String(format: "composition: %d segments, %.2f s long, built in %.0f ms",
                 cc.segments, cc.composition.duration.seconds, cc.buildSeconds * 1000))

    let item = AVPlayerItem(asset: cc.composition)
    if !CommandLine.arguments.contains("--no-compositor") { item.videoComposition = cc.videoComposition }
    item.audioTimePitchAlgorithm = .spectral
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
    item.add(output)
    // Muted: the test file beeps every second and must not play through the speakers.
    let player = await MainActor.run { () -> AVPlayer in let p = AVPlayer(playerItem: item); p.isMuted = true; return p }

    // Wait until the item can play.
    while item.status == .unknown { try await Task.sleep(nanoseconds: 10_000_000) }
    guard item.status == .readyToPlay else { throw item.error ?? NSError(domain: "probe", code: 10) }
    // Let the first frames preroll, as a player does before the user presses play.
    _ = await player.preroll(atRate: 1)

    MetalCompositor.timings.reset()
    let cpu0 = cpuSeconds()
    let wall0 = CACurrentMediaTime()
    await MainActor.run { player.play() }

    // Poll like a display link would, on a dedicated high-priority queue, at 240 Hz.
    // Pixels are only read near sync marks, so polling stays cheap.
    let limit = min(seconds, cc.composition.duration.seconds - 0.1)
    let marks = cc.marks
    final class Box: @unchecked Sendable { var a: [(wall: Double, item: Double, white: Bool)] = [] }
    let box = Box()
    let q = DispatchQueue(label: "poll", qos: .userInteractive)
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: q)
    timer.schedule(deadline: .now(), repeating: .nanoseconds(4_166_667), leeway: .nanoseconds(0))
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        var done = false
        timer.setEventHandler {
            if done { return }
            let now = CACurrentMediaTime()
            let t = output.itemTime(forHostTime: now)
            if output.hasNewPixelBuffer(forItemTime: t),
               let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                let nearMark = marks.contains { abs($0 - t.seconds) < 0.1 }
                box.a.append((now - wall0, t.seconds, nearMark && isWhite(pb)))
            }
            if t.seconds >= limit || now - wall0 > limit * 2 + 5 {
                done = true
                timer.cancel()
                c.resume()
            }
        }
        timer.resume()
    }
    let arrivals = box.a
    let waiting = await MainActor.run { (player.timeControlStatus.rawValue, player.reasonForWaitingToPlay?.rawValue ?? "-") }
    await MainActor.run { player.pause() }
    if arrivals.isEmpty {
        print("no frames; item status \(item.status.rawValue), error \(String(describing: item.error)), player \(waiting)")
    }
    let wall = CACurrentMediaTime() - wall0
    let cpu = cpuSeconds() - cpu0

    // Frame pacing.
    let played = arrivals.last?.item ?? 0
    let fps = 1 / cc.videoComposition.frameDuration.seconds
    let expected = Int((played - (arrivals.first?.item ?? 0)) * fps) + 1
    var gaps: [Double] = []
    for i in 1..<max(1, arrivals.count) { gaps.append(arrivals[i].wall - arrivals[i - 1].wall) }
    let late = gaps.filter { $0 > 1.5 / fps }.count
    let render = MetalCompositor.timings.snapshot().map { Double($0) / 1e6 }.sorted()

    // Sync marks: the first white frame after each mark should be the frame that contains it.
    var markErrors: [Int] = []
    for m in cc.marks where m > (arrivals.first?.item ?? 0) + 0.1 && m < played - 0.1 {
        let expectedFrame = Int((m * fps).rounded(.up))
        if let first = arrivals.first(where: { $0.white && $0.item >= m - 0.05 }) {
            markErrors.append(Int((first.item * fps).rounded()) - expectedFrame)
        }
    }

    print(String(format: "played %.2f s of timeline in %.2f s wall", played, wall))
    print("frames: \(arrivals.count) arrived, \(expected) expected, \(late) gaps longer than 1.5 frames")
    print(String(format: "longest gap between frames: %.1f ms", (gaps.max() ?? 0) * 1000))
    let lateAt = gaps.enumerated().filter { $0.element > 1.5 / fps }
        .map { String(format: "%.2fs:%.0fms", arrivals[$0.offset + 1].item, $0.element * 1000) }
    if !lateAt.isEmpty { print("late frames at timeline time: \(lateAt.prefix(12).joined(separator: " "))") }
    print(String(format: "render per frame: median %.2f ms, p99 %.2f ms, max %.2f ms",
                 pct(render, 0.5), pct(render, 0.99), render.last ?? 0))
    print(String(format: "CPU: %.0f%% of one core on average", cpu / wall * 100))
    print(String(format: "memory: %.0f MB footprint", footprintMB()))
    let off = markErrors.filter { $0 != 0 }
    print("sync marks checked in playback: \(markErrors.count), off by a frame or more: \(off.count) \(off.prefix(10))")
    if let log = item.accessLog()?.events.last {
        print("player dropped-frame counter: \(log.numberOfDroppedVideoFrames)")
    }
}

/// Reads the centre pixel of an RGBA half-float buffer and tests for white.
func isWhite(_ pb: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
    let row = CVPixelBufferGetBytesPerRow(pb)
    let x = CVPixelBufferGetWidth(pb) / 2, y = CVPixelBufferGetHeight(pb) / 2
    let p = (base + y * row + x * 8).assumingMemoryBound(to: Float16.self)
    return p[0] > 0.9 && p[1] > 0.9 && p[2] > 0.9
}

func pct(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
