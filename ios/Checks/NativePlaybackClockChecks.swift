enum NativePlaybackClockChecks {
    static func run() {
        let start = ContinuousClock().now
        var clock = NativePlaybackClock()
        precondition(clock.observe(0, at: start) == 0)
        precondition(clock.bufferDeadline(since: start) == start + .seconds(7))

        let coarseSample = start + .seconds(3)
        precondition(clock.observe(3, at: coarseSample) == 3,
                     "A delayed observation must retain evidence that audio started")
        let renewed = start + .seconds(6)
        precondition(clock.observe(6, at: renewed) == 3)
        precondition(clock.bufferDeadline(since: start) == renewed + .seconds(12),
                     "The stream has a post-start budget since its latest observed motion")
        precondition(clock.observe(6, at: renewed + .seconds(3)) == 0)
        precondition(clock.bufferDeadline(since: start) == renewed + .seconds(12),
                     "Repeated stale snapshots must not extend the deadline")

        let pause = start + .seconds(10)
        clock.rebase(to: 65)
        precondition(clock.observe(65, at: pause) == 0, "An explicit seek is not clock progress")
        precondition(clock.bufferDeadline(since: start) == renewed + .seconds(12))
        precondition(clock.bufferDeadline(since: pause) == pause + .seconds(12))

        let restart = start + .seconds(12)
        precondition(clock.observe(.infinity, at: restart) == 0)
        clock.rebase(to: .nan)
        precondition(clock.observe(0, at: restart) == 0, "A backwards jump must update the motion baseline")
        precondition(clock.observe(0.006, at: restart) == 0)
        precondition(clock.observe(0.012, at: restart) == 0.012, "Sub-threshold motion can accumulate")
        precondition(clock.bufferDeadline(since: pause) == restart + .seconds(12))

        let nextItem = NativePlaybackClock()
        precondition(nextItem.bufferDeadline(since: restart) == restart + .seconds(7),
                     "The next item must start with no evidence inherited from the old item")
        print("PASS: native playback clock accepts coarse samples while keeping startup, seek, and stale deadlines separate")
    }
}
