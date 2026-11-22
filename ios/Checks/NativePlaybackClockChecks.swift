enum NativePlaybackClockChecks {
    static func run() {
        let start = ContinuousClock().now
        var clock = NativePlaybackClock()
        precondition(clock.observe(0, at: start) == 0)
        precondition(clock.bufferDeadline(since: start) == start + .seconds(7))
        precondition(clock.bufferDeadline(since: start, waitingForBufferedPlayback: true) == start + .seconds(34),
                     "A ready item with buffered data can finish the player's startup buffering window")

        let coarseSample = start + .seconds(3)
        precondition(clock.observe(3, at: coarseSample) == 3,
                     "A delayed observation must retain evidence that audio started")
        let renewed = start + .seconds(6)
        precondition(clock.observe(6, at: renewed) == 3)
        precondition(clock.bufferDeadline(since: start) == renewed + .seconds(12),
                     "The stream has a post-start budget since its latest observed motion")
        precondition(clock.bufferDeadline(since: start, waitingForBufferedPlayback: true) == renewed + .seconds(12),
                     "Buffered startup grace must not extend a later playback stall")
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
        checkNativeMotionWatchdog()
        checkNativeSeekState()
        checkNativeSeekBufferAvailability()
        checkNativeEndOrdering()
    }

    private static func checkNativeMotionWatchdog() {
        let start = ContinuousClock().now
        var clock = NativePlaybackClock()
        clock.rebase(to: 0)
        precondition(clock.motionWatchdogDeadline(since: start) == start + .seconds(3))

        let advanced = start + .seconds(2)
        precondition(clock.observe(2, at: advanced) == 2)
        let stale = start + .seconds(4)
        precondition(clock.observe(2, at: stale) == 0)
        precondition(clock.observe(.infinity, at: stale) == 0)
        clock.observeBuffer(through: 30, at: stale)
        precondition(clock.motionWatchdogDeadline(since: start) == advanced + .seconds(3),
                     "Unchanged or invalid samples and new buffer bytes cannot substitute for media motion")

        let delayed = start + .seconds(8)
        precondition(clock.observe(8, at: delayed) == 6)
        precondition(clock.motionWatchdogDeadline(since: start) == delayed + .seconds(3),
                     "A delayed callback that finds current media motion must renew the deadline")

        let restart = start + .seconds(60)
        clock.rebase(to: 90)
        precondition(clock.observe(90, at: restart) == 0)
        precondition(clock.motionWatchdogDeadline(since: restart) == restart + .seconds(3),
                     "Resuming after pause or seek starts a fresh watchdog without treating the seek as motion")
        print("PASS: native motion watchdog requires advancing media and resets its window after a pause or seek")
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

    private static func checkNativeEndOrdering() {
        let duration = 30.0
        // Simulate an end callback queued before the user's backward seek. The old
        // media time can still be at the end while that request is pending.
        precondition(!NativePlaybackEndPolicy.acceptsNotification(time: 30, duration: duration, seeking: true),
                     "A queued end event must not replace a pending seek")
        // Its delivery can also lag behind successful seek completion on the same item.
        precondition(!NativePlaybackEndPolicy.acceptsNotification(time: 8, duration: duration, seeking: false),
                     "An old end event must not advance after the real media clock moved away")
        precondition(NativePlaybackEndPolicy.isAtEnd(time: 30, duration: duration),
                     "A completed seek to the physical end must permit queue advance or repeat")
        precondition(NativePlaybackEndPolicy.isAtEnd(time: 29.99, duration: duration))
        precondition(!NativePlaybackEndPolicy.isAtEnd(time: 29.9, duration: duration),
                     "A nearby lyric or progress selection is not an end")
        precondition(!NativePlaybackEndPolicy.isAtEnd(time: 0, duration: 0.02),
                     "Repeating a short audio item at zero must not recursively finish it")
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            precondition(!NativePlaybackEndPolicy.acceptsNotification(time: invalid, duration: duration, seeking: false))
        }
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            precondition(!NativePlaybackEndPolicy.isAtEnd(time: duration, duration: invalid),
                         "An unknown duration cannot synthesize an end after a seek")
            precondition(NativePlaybackEndPolicy.acceptsNotification(time: duration, duration: invalid, seeking: false),
                         "An actual end notification still works for streams without a known duration")
            precondition(!NativePlaybackEndPolicy.acceptsNotification(time: duration, duration: invalid, seeking: true))
        }
        print("PASS: simulated native end ordering rejects pending and stale callbacks while preserving seek-to-end")
    }

    private static func checkNativeSeekBufferAvailability() {
        let separated = [(start: 0.0, end: 15.0), (start: 120.0, end: 150.0)]
        precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: 112.572, in: separated),
                     "A moved playhead cannot confirm a seek when its target bytes are absent")
        precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: 50, in: separated),
                     "A later buffered range cannot fill an earlier gap")
        precondition(NativeSeekBufferAvailability.hasForwardBuffer(at: 120, in: separated))
        precondition(NativeSeekBufferAvailability.hasForwardBuffer(at: 149.980, in: separated))
        precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: 149.999, in: separated),
                     "A nearly exhausted range cannot confirm playable media at the target")
        precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: 150, in: separated),
                     "The end of a loaded range is exclusive")
        precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: 15, in: separated))
        precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: 7.5, in: []))
        precondition(NativeSeekBufferAvailability.hasForwardBuffer(at: 7.5, in: [(start: 7.5, end: 8.0)]),
                     "The requested time becomes ready when its own range arrives")
        precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: 112.572, in: [(start: 112.572, end: 112.5722)]),
                     "A sub-millisecond placeholder must not look like buffered audio after a stalled seek")
        let invalid = [(start: Double.nan, end: 20.0), (start: 0.0, end: Double.infinity),
                       (start: 12.0, end: 8.0), (start: 7.5, end: 7.5)]
        precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: 7.5, in: invalid))
        for time in [Double.nan, .infinity, -.infinity, -1] {
            precondition(!NativeSeekBufferAvailability.hasForwardBuffer(at: time, in: separated))
        }
        print("PASS: native seek readiness requires forward media at its actual target")
    }
}
