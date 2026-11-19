import Foundation

struct NativePlaybackClock {
    private var previousTime: Double?
    private var lastAdvance: ContinuousClock.Instant?
    private var bufferedEnd = 0.0
    private var lastBufferAdvance: ContinuousClock.Instant?

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

    func bufferDeadline(since start: ContinuousClock.Instant, waitingForBufferedPlayback: Bool = false) -> ContinuousClock.Instant {
        let bufferActivity = lastBufferAdvance ?? start
        guard let lastAdvance else {
            if waitingForBufferedPlayback { return start + .seconds(34) }
            return max(start, bufferActivity) + .seconds(7)
        }
        return max(start, lastAdvance, bufferActivity) + .seconds(12)
    }

    mutating func observeBuffer(through end: Double, at now: ContinuousClock.Instant) {
        guard end.isFinite, end > bufferedEnd + 0.01 else { return }
        bufferedEnd = end
        lastBufferAdvance = now
    }
}

struct NativeSeekState: Sendable {
    struct Request: Equatable, Sendable {
        let id: UUID
        let previousPosition: Double
        let deadline: ContinuousClock.Instant
    }

    private(set) var request: Request?

    mutating func begin(from confirmedPosition: Double, at now: ContinuousClock.Instant) -> Request {
        let previous = request?.previousPosition ?? (confirmedPosition.isFinite ? max(0, confirmedPosition) : 0)
        let next = Request(id: UUID(), previousPosition: previous, deadline: now + .seconds(12))
        request = next
        return next
    }

    mutating func complete(_ id: UUID) -> Request? {
        guard request?.id == id else { return nil }
        defer { request = nil }
        return request
    }

    mutating func expire(_ id: UUID, at now: ContinuousClock.Instant) -> Request? {
        guard let request, request.id == id, now >= request.deadline else { return nil }
        return complete(id)
    }

    mutating func reset() { request = nil }
}

enum NativePlaybackEndPolicy {
    // Compressed audio may report the final sample within one frame of its duration.
    static func isAtEnd(time: Double, duration: Double) -> Bool {
        guard time.isFinite, time >= 0, duration.isFinite, duration > 0 else { return false }
        return time >= duration - min(0.05, duration * 0.001)
    }

    static func acceptsNotification(time: Double, duration: Double, seeking: Bool) -> Bool {
        guard !seeking, time.isFinite, time >= 0 else { return false }
        // Some streams report their duration only at completion. Preserve their real
        // end notification when there is no known end against which to reject it.
        if !duration.isFinite || duration <= 0 { return true }
        return isAtEnd(time: time, duration: duration)
    }
}
