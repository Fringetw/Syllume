struct NativePlaybackClock {
    private var previousTime: Double?
    private var lastAdvance: ContinuousClock.Instant?

    mutating func rebase(to time: Double) {
        guard time.isFinite else { return }
        previousTime = time
    }

    mutating func observe(_ time: Double, at now: ContinuousClock.Instant) -> Double {
        guard time.isFinite else { return 0 }
        guard let previousTime else { rebase(to: time); return 0 }
        let advance = time - previousTime
        if advance < 0 || !advance.isFinite {
            rebase(to: time)
            return 0
        }
        guard advance >= 0.01 else { return 0 }
        rebase(to: time)
        lastAdvance = now
        return advance
    }

    func bufferDeadline(since start: ContinuousClock.Instant) -> ContinuousClock.Instant {
        guard let lastAdvance else { return start + .seconds(7) }
        return max(start, lastAdvance) + .seconds(12)
    }
}
