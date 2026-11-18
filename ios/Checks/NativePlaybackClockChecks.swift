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
        var loading = NativePlaybackClock()
        loading.rebase(to: 0)
        loading.observeBuffer(through: 4, at: start + .seconds(6))
        precondition(loading.bufferDeadline(since: start) == start + .seconds(13),
                     "Real buffer delivery must extend a pending initial play")
        loading.observeBuffer(through: 4, at: start + .seconds(12))
        precondition(loading.bufferDeadline(since: start) == start + .seconds(13),
                     "A repeated buffer snapshot cannot extend the wait indefinitely")
        loading.observeBuffer(through: .infinity, at: start + .seconds(13))
        loading.observeBuffer(through: 8, at: start + .seconds(13))
        precondition(loading.bufferDeadline(since: start) == start + .seconds(20))
        precondition(loading.observe(2, at: start + .seconds(14)) == 2)
        precondition(loading.bufferDeadline(since: start) == start + .seconds(26))
        print("PASS: native playback clock accepts coarse samples and buffer delivery while bounding unchanged media")
        checkNativeSeekState()
    }

    private static func checkNativeSeekState() {
        let now = ContinuousClock().now
        var seek = NativeSeekState()
        let first = seek.begin(from: 8, at: now)
        precondition(seek.expire(first.id, at: now + .seconds(11)) == nil)
        precondition(seek.request?.id == first.id, "A pending seek must remain bounded while playback is paused")

        let latest = seek.begin(from: 70, at: now + .seconds(4))
        precondition(latest.previousPosition == 8, "An optimistic seek preview is not the last confirmed position")
        precondition(seek.complete(first.id) == nil && seek.expire(first.id, at: now + .seconds(30)) == nil,
                     "An old callback and deadline cannot finish a newer seek")
        precondition(seek.expire(latest.id, at: now + .seconds(15)) == nil)
        let timedOut = seek.expire(latest.id, at: now + .seconds(16))
        precondition(timedOut?.previousPosition == 8 && seek.request == nil)
        precondition(seek.complete(latest.id) == nil, "A late completion cannot reopen an expired seek")

        let retry = seek.begin(from: 9, at: now + .seconds(18))
        precondition(seek.complete(retry.id)?.previousPosition == 9)
        precondition(seek.request == nil, "A normal completion must clear its deadline")
        let oldItem = seek.begin(from: 3, at: now + .seconds(20))
        seek.reset()
        let nextItem = seek.begin(from: 0, at: now + .seconds(21))
        precondition(seek.complete(oldItem.id) == nil && seek.expire(oldItem.id, at: now + .seconds(40)) == nil)
        precondition(nextItem.previousPosition == 0 && seek.complete(nextItem.id) != nil,
                     "The next item's seek must not inherit the old item's confirmed time")
        print("PASS: native seek deadlines, superseded completions, retry and item reset")
    }
}
