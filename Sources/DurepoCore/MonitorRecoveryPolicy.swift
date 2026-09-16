import Foundation

public enum MonitorRecoveryPolicy {
    public static func requiresStartupScan(
        lastCommittedEventID: UInt64,
        hasPendingEvents: Bool,
        needsFullScan: Bool,
        sessionChanged: Bool
    ) -> Bool {
        lastCommittedEventID == 0 || hasPendingEvents || needsFullScan || sessionChanged
    }
}

public struct SnapshotPageLoadState: Sendable {
    public private(set) var isLoading = false
    private var generation = UUID()

    public init() {}

    public mutating func reset() {
        generation = UUID()
        isLoading = false
    }

    public mutating func begin() -> UUID? {
        guard !isLoading else { return nil }
        generation = UUID()
        isLoading = true
        return generation
    }

    public mutating func finish(_ request: UUID) -> Bool {
        guard isLoading, request == generation else { return false }
        isLoading = false
        return true
    }
}
