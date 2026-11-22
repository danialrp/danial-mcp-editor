import Testing
@testable import EditorCore

@Suite struct TimeTests {
    @Test func frameAndSampleDurationsAreExact() {
        #expect(FrameRate.fps60.frameDuration.ticks == 4_000)
        #expect(FrameRate.fps30.frameDuration.ticks == 8_000)
        #expect(Time.ticksPerSecond % 48_000 == 0)
    }

    @Test func unsupportedRatesAreRejected() {
        #expect(FrameRate(fps: 0) == nil)
        #expect(FrameRate(fps: 7) == nil)
        #expect(FrameRate(fps: 24) != nil)
    }

    @Test func snappingGoesToNearestFrame() {
        let r = FrameRate.fps60
        #expect(Time(ticks: 1_999).snapped(to: r).ticks == 0)
        #expect(Time(ticks: 2_000).snapped(to: r).ticks == 0)
        #expect(Time(ticks: 2_001).snapped(to: r).ticks == 4_000)
    }

    @Test func frameIndexOfNegativeTimeRoundsDown() {
        #expect(Time(ticks: -1).frameIndex(at: .fps60) == -1)
        #expect(Time(ticks: 3_999).frameIndex(at: .fps60) == 0)
    }

    @Test func manyCutsDoNotDrift() {
        // 1,000 one-frame steps land exactly on frame 1,000.
        var t = Time.zero
        for _ in 0..<1_000 { t = t + FrameRate.fps60.frameDuration }
        #expect(t == FrameRate.fps60.time(ofFrame: 1_000))
        #expect(t.seconds == 1_000.0 / 60.0)
    }

    @Test func rangesAreHalfOpen() {
        let r = TimeRange(start: Time(ticks: 10), end: Time(ticks: 20))
        #expect(r.contains(Time(ticks: 10)))
        #expect(!r.contains(Time(ticks: 20)))
        #expect(r.duration.ticks == 10)
    }
}

@Suite struct TimeEdgeTests {
    @Test func nonFiniteSecondsBecomeZero() {
        #expect(Time(seconds: .nan) == .zero)
        #expect(Time(seconds: .infinity) == .zero)
    }
}
