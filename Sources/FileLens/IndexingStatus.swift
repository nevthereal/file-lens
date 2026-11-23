import Foundation

struct IndexingStatus {
    enum Phase { case idle, running, paused, complete, failed }
    private(set) var phase: Phase = .idle
    private(set) var startedAt: TimeInterval?
    private(set) var stoppedAt: TimeInterval?
    private(set) var fraction: Double?
    private(set) var scope = ""

    mutating func start(scope: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self = IndexingStatus()
        self.scope = scope
        startedAt = now
        phase = .running
    }

    mutating func update(_ value: Double) {
        guard phase == .running, value.isFinite else { return }
        // Reserve 100% for the actual completion event, including empty folders.
        fraction = max(fraction ?? 0, min(0.999, max(0, value)))
    }

    mutating func stop(_ phase: Phase, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard self.phase == .running else { return }
        self.phase = phase
        stoppedAt = now
        if phase == .complete { fraction = 1 }
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (stoppedAt ?? now) - startedAt)
    }

    func remaining(at now: TimeInterval) -> TimeInterval? {
        guard phase == .running, let fraction, fraction >= 0.005, elapsed(at: now) >= 3 else { return nil }
        let estimate = elapsed(at: now) * (1 - fraction) / fraction
        return estimate.isFinite ? max(0, estimate) : nil
    }

    static func elapsedText(_ interval: TimeInterval) -> String {
        let seconds = Int(min(315_360_000, max(0, interval)))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    static func remainingText(_ interval: TimeInterval) -> String {
        let seconds = min(315_360_000, max(0, interval))
        if seconds >= 3600 { return "~\(Int(ceil(seconds / 3600))) hr remaining" }
        if seconds >= 60 { return "~\(Int(ceil(seconds / 60))) min remaining" }
        return "~\(max(5, Int(ceil(seconds / 5)) * 5)) sec remaining"
    }
}
