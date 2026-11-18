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

    func bufferDeadline(since start: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let bufferActivity = lastBufferAdvance ?? start
        guard let lastAdvance else { return max(start, bufferActivity) + .seconds(7) }
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
