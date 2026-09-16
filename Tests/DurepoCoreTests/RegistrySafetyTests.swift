import Foundation
import XCTest
@testable import DurepoCore

final class RegistrySafetyTests: XCTestCase, @unchecked Sendable {
    func testFieldUpdatesPreserveCompletedAgentHandoff() async throws {
        try await withStorage { storage in
            let gui = RepositoryRegistry(storageURL: storage)
            let agent = RepositoryRegistry(storageURL: storage)
            let original = RepositoryRecord(displayName: "Example", bookmark: Data([1]), handoffBookmark: Data([2]))
            try await gui.add(original)
            try await agent.updateAgentBookmark(id: original.id, bookmark: Data([3]))
            let edited = try await gui.updateExclusionRules(id: original.id, rules: ["build/"])
            XCTAssertEqual(edited.agentBookmark, Data([3]))
            XCTAssertNil(edited.handoffBookmark)
            XCTAssertEqual(edited.customExclusionRules, ["build/"])
            let lateHandoff = try await gui.updateHandoffBookmark(id: original.id, bookmark: Data([4]))
            XCTAssertNil(lateHandoff.handoffBookmark)
            XCTAssertEqual(lateHandoff.agentBookmark, Data([3]))

            let inheriting = try await gui.updateExclusionRules(id: original.id, rules: nil)
            XCTAssertNil(inheriting.customExclusionRules)
            XCTAssertEqual(inheriting.agentBookmark, Data([3]))
            XCTAssertEqual(inheriting.effectiveExclusionRules(globalRules: ["new-default/"]).rules, ["new-default/"])
        }
    }

    func testLegacyUpdatePreservesAgentBookmarkAndCannotResurrectRemoval() async throws {
        try await withStorage { storage in
            let registry = RepositoryRegistry(storageURL: storage)
            let original = RepositoryRecord(displayName: "Example", bookmark: Data([1]), handoffBookmark: Data([2]))
            try await registry.add(original)
            try await registry.updateAgentBookmark(id: original.id, bookmark: Data([3]))
            try await registry.update(original)
            let records = try await registry.records()
            XCTAssertEqual(records.first?.agentBookmark, Data([3]))
            XCTAssertNil(records.first?.handoffBookmark)
            try await registry.remove(id: original.id)
            do {
                try await registry.update(original)
                XCTFail("An update must not recreate a removed registration")
            } catch DurepoError.repositoryNotRegistered {
            }
            do {
                try await registry.updateAgentBookmark(id: original.id, bookmark: Data([4]))
                XCTFail("A late agent handoff must not recreate a removed registration")
            } catch DurepoError.repositoryNotRegistered {
            }
            let remaining = try await registry.records()
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testIndependentRegistriesSerializeReadModifyWrite() async throws {
        try await withStorage { storage in
            let records = (0..<40).map {
                RepositoryRecord(displayName: "Repository \($0)", bookmark: Data([UInt8($0)]))
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for record in records {
                    group.addTask {
                        let registry = RepositoryRegistry(storageURL: storage)
                        try await registry.add(record)
                    }
                }
                try await group.waitForAll()
            }
            let reader = RepositoryRegistry(storageURL: storage)
            let stored = try await reader.records()
            XCTAssertEqual(Set(stored.map(\.id)), Set(records.map(\.id)))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, record) in records.enumerated() {
                    group.addTask {
                        let registry = RepositoryRegistry(storageURL: storage)
                        if index.isMultiple(of: 2) {
                            try await registry.remove(id: record.id)
                        } else {
                            try await registry.updateExclusionRules(id: record.id, rules: ["output/"])
                        }
                    }
                }
                try await group.waitForAll()
            }
            let remaining = try await reader.records()
            XCTAssertEqual(Set(remaining.map(\.id)), Set(records.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element.id)))
            XCTAssertTrue(remaining.allSatisfy { $0.customExclusionRules == ["output/"] })
        }
    }

    func testAppBookmarkRenewalPreservesOtherFields() async throws {
        try await withStorage { storage in
            let registry = RepositoryRegistry(storageURL: storage)
            let record = RepositoryRecord(displayName: "Example", bookmark: Data([1]))
            try await registry.add(record)
            try await registry.updateAgentBookmark(id: record.id, bookmark: Data([2]))
            try await registry.updateExclusionRules(id: record.id, rules: ["output/"])
            let refreshed = try await registry.updateAppBookmark(id: record.id, bookmark: Data([3]))
            XCTAssertEqual(refreshed.bookmark, Data([3]))
            XCTAssertEqual(refreshed.agentBookmark, Data([2]))
            XCTAssertEqual(refreshed.customExclusionRules, ["output/"])
        }
    }

    func testRestoreAccessReplacementRejectsOldAgentHandoff() async throws {
        try await withStorage { storage in
            let registry = RepositoryRegistry(storageURL: storage)
            let record = RepositoryRecord(displayName: "Example", bookmark: Data([1]), customExclusionRules: ["output/"])
            try await registry.add(record)
            try await registry.updateAgentBookmark(id: record.id, bookmark: Data([2]))
            try await registry.setEnabled(id: record.id, isEnabled: false)
            let rebound = try await registry.replaceRepositoryAccess(
                id: record.id, bookmark: Data([3]), handoffBookmark: Data([4]), isEnabled: true
            )
            XCTAssertEqual(rebound.bookmark, Data([3]))
            XCTAssertNil(rebound.agentBookmark)
            XCTAssertTrue(rebound.isEnabled)
            XCTAssertEqual(rebound.customExclusionRules, ["output/"])
            do {
                try await registry.updateAgentBookmark(id: record.id, bookmark: Data([5]), matchingAppBookmark: record.bookmark)
                XCTFail("An old session must not restore access to the retained rollback tree")
            } catch RepositoryRegistryError.accessChanged {
            }
            let current = try await registry.updateAgentBookmark(id: record.id, bookmark: Data([6]), matchingAppBookmark: rebound.bookmark)
            XCTAssertEqual(current.agentBookmark, Data([6]))
            XCTAssertNil(current.handoffBookmark)
        }
    }

    func testCleanZeroCursorAlwaysRequiresStartupScan() {
        XCTAssertTrue(MonitorRecoveryPolicy.requiresStartupScan(
            lastCommittedEventID: 0, hasPendingEvents: false, needsFullScan: false, sessionChanged: false
        ))
        XCTAssertFalse(MonitorRecoveryPolicy.requiresStartupScan(
            lastCommittedEventID: 42, hasPendingEvents: false, needsFullScan: false, sessionChanged: false
        ))
        XCTAssertTrue(MonitorRecoveryPolicy.requiresStartupScan(
            lastCommittedEventID: 42, hasPendingEvents: false, needsFullScan: false, sessionChanged: true
        ))
        XCTAssertTrue(MonitorRecoveryPolicy.requiresStartupScan(
            lastCommittedEventID: 42, hasPendingEvents: true, needsFullScan: false, sessionChanged: false
        ))
    }

    func testRestartAfterCommittingZeroCursorStillRequestsScan() async throws {
        try await withStorage { storage in
            let id = UUID()
            let store = SnapshotStore(storageURL: storage)
            _ = try await store.prepareMonitor(repositoryID: id, volumeID: "volume", rootID: "root")
            _ = try await store.commitEvents(repositoryID: id, through: 0)
            let restarted = SnapshotStore(storageURL: storage)
            let state = try await restarted.prepareMonitor(repositoryID: id, volumeID: "volume", rootID: "root")
            XCTAssertEqual(state.lastCommittedEventID, 0)
            XCTAssertTrue(MonitorRecoveryPolicy.requiresStartupScan(
                lastCommittedEventID: state.lastCommittedEventID,
                hasPendingEvents: state.hasPendingEvents,
                needsFullScan: state.needsFullScan,
                sessionChanged: false
            ))
        }
    }

    func testModeResetDiscardsOldPageWithoutFinishingNewRequest() throws {
        var state = SnapshotPageLoadState()
        let old = try XCTUnwrap(state.begin())
        XCTAssertNil(state.begin())
        state.reset()
        let current = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.finish(old))
        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(state.finish(current))
        XCTAssertFalse(state.isLoading)
        let next = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.finish(current))
        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(state.finish(next))
    }

    private func withStorage(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/RegistrySafetyTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                XCTFail("Could not remove isolated test storage: \(error)")
            }
        }
        try await body(root)
    }
}
