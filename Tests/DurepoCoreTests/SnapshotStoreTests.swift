import Darwin
import Foundation
import Testing
@testable import DurepoCore

@Suite("Snapshot store")
struct SnapshotStoreTests {
    @Test("Repository records remain compatible with pre-agent-bookmark data")
    func legacyRepositoryRecordDecoding() throws {
        let json = #"{"id":"3271F239-D6F3-474E-8C77-E9DAFC5EDF67","displayName":"m2horizon","bookmark":"AQID","addedAt":"2026-07-17T03:02:29Z","isEnabled":true}"#
        let record = try JSONDecoder.durepo.decode(
            RepositoryRecord.self,
            from: Data(json.utf8)
        )

        #expect(record.displayName == "m2horizon")
        #expect(record.bookmark == Data([1, 2, 3]))
        #expect(record.agentBookmark == nil)
        #expect(record.handoffBookmark == nil)
        #expect(record.customExclusionRules == nil)
    }

    @Test("Exclusion rules use gitignore-compatible matching syntax")
    func gitIgnoreCompatibleExclusionRules() {
        let rules = ExclusionRuleSet([
            "# generated files",
            "*.log",
            "!/keep.log",
            "cache/",
            "generated/**/tmp[0-9].dat",
            "\\#literal",
        ])

        #expect(rules.rules.first == "# generated files")
        #expect(rules.excludes("debug.log"))
        #expect(!rules.excludes("keep.log"))
        #expect(rules.excludes("nested/keep.log"))
        #expect(rules.excludes("cache/file.bin"))
        #expect(rules.excludes("generated/a/b/tmp7.dat"))
        #expect(rules.excludes("#literal"))
        #expect(!rules.excludes("generated/a/b/tmpx.dat"))
        #expect(!rules.excludes(".git/config"))
    }

    @Test("Negated rules cannot reinclude a file below an excluded parent")
    func excludedParentCannotBeReincluded() {
        let blocked = ExclusionRuleSet(["output/", "!output/keep.txt"])
        #expect(blocked.excludes("output/keep.txt"))

        let allowed = ExclusionRuleSet(["output/", "!output/", "!output/keep.txt"])
        #expect(!allowed.excludes("output/keep.txt"))
    }

    @Test("Global exclusion rules persist including an empty rule list")
    func globalExclusionRulePersistence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = GlobalExclusionRuleStore(storageURL: fixture.storage)

        #expect(try store.rules() == ExclusionRuleSet.defaults.rules)
        try store.save(["*.log", "!important.log"])
        #expect(try store.rules() == ["*.log", "!important.log"])
        try store.save([])
        #expect(try store.rules().isEmpty)
    }

    @Test("Repository optimizer uses ecosystem evidence without importing gitignore")
    func repositoryExclusionOptimization() async throws {
        try await withFixture { fixture in
            try fixture.write(#"{"dependencies":{"next":"latest"}}"#, to: "web/package.json")
            try fixture.write("dependency", to: "web/node_modules/package/index.js")
            try fixture.write("output", to: "web/.next/server/app.js")
            try fixture.write("[project]\nname = \"sample\"\n", to: "pyproject.toml")
            try fixture.write("cache", to: ".venv/lib/cache.py")
            try fixture.write("metadata", to: ".DS_Store")
            try fixture.write("local-only/\n", to: ".gitignore")

            let optimizer = RepositoryExclusionOptimizer()
            let result = try await optimizer.optimize(
                repositoryURL: fixture.repository,
                including: ["*.log"]
            )

            #expect(result.rules.first == "*.log")
            #expect(result.rules.contains("web/node_modules/"))
            #expect(result.rules.contains("web/.next/"))
            #expect(result.rules.contains(".venv/"))
            #expect(result.rules.contains(".DS_Store"))
            #expect(!result.rules.contains("local-only/"))
            #expect(result.detectedTechnologies.contains("Node.js"))
            #expect(result.detectedTechnologies.contains("Next.js"))
            #expect(result.detectedTechnologies.contains("Python"))
        }
    }

    @Test("Repository optimizer does not infer a generic output directory without an ecosystem marker")
    func repositoryExclusionOptimizationRequiresEvidence() async throws {
        try await withFixture { fixture in
            try fixture.write("valuable", to: "target/report.txt")

            let result = try await RepositoryExclusionOptimizer().optimize(
                repositoryURL: fixture.repository,
                including: []
            )

            #expect(result.rules.isEmpty)
            #expect(result.detectedTechnologies.isEmpty)
        }
    }

    @Test("Repository optimizer never suggests a rule that matches Git-tracked content")
    func repositoryExclusionOptimizationProtectsTrackedContent() async throws {
        try await withFixture { fixture in
            try fixture.write(#"{"name":"tracked-dependency"}"#, to: "package.json")
            try fixture.write("valuable", to: "node_modules/local/index.js")
            try fixture.runGit(["init", "--quiet"])
            try fixture.runGit(["add", "package.json", "node_modules/local/index.js"])

            let result = try await RepositoryExclusionOptimizer().optimize(
                repositoryURL: fixture.repository,
                including: []
            )

            #expect(!result.rules.contains("node_modules/"))
            #expect(result.trackedSuggestionCount == 1)
            #expect(!result.gitTrackingVerificationFailed)
        }
    }

    @Test("Repository optimizer does not duplicate a broader existing rule")
    func repositoryExclusionOptimizationAvoidsSemanticDuplicates() async throws {
        try await withFixture { fixture in
            try fixture.write(#"{"name":"workspace"}"#, to: "web/package.json")
            try fixture.write("dependency", to: "web/node_modules/package/index.js")

            let result = try await RepositoryExclusionOptimizer().optimize(
                repositoryURL: fixture.repository,
                including: ["node_modules/"]
            )

            #expect(result.rules == ["node_modules/"])
            #expect(result.suggestions.isEmpty)
        }
    }

    @Test("Repository optimizer preserves existing negation intent")
    func repositoryExclusionOptimizationPreservesNegation() async throws {
        try await withFixture { fixture in
            try fixture.write(#"{"name":"workspace"}"#, to: "package.json")
            try fixture.write("valuable", to: "node_modules/local/index.js")

            let result = try await RepositoryExclusionOptimizer().optimize(
                repositoryURL: fixture.repository,
                including: ["!node_modules/local/index.js"]
            )

            #expect(result.rules == ["!node_modules/local/index.js"])
            #expect(result.suggestions.isEmpty)
        }
    }

    @Test("Repository optimizer fails closed when a Git index cannot be verified")
    func repositoryExclusionOptimizationFailsClosed() async throws {
        try await withFixture { fixture in
            try fixture.write(#"{"name":"broken-git"}"#, to: "package.json")
            try fixture.write("dependency", to: "node_modules/package/index.js")
            try FileManager.default.createDirectory(
                at: fixture.repository.appending(path: ".git"),
                withIntermediateDirectories: true
            )

            let result = try await RepositoryExclusionOptimizer().optimize(
                repositoryURL: fixture.repository,
                including: ["*.log"]
            )

            #expect(result.rules == ["*.log"])
            #expect(result.suggestions.isEmpty)
            #expect(result.gitTrackingVerificationFailed)
        }
    }

    @Test("Snapshots and restores worktree, .git, and symlinks")
    func roundTrip() async throws {
        try await withFixture { fixture in
            try fixture.write("hello", to: "Sources/main.swift")
            try fixture.write("ref: refs/heads/main\n", to: ".git/HEAD")
            try FileManager.default.createSymbolicLink(
                atPath: fixture.repository.appending(path: "current").path,
                withDestinationPath: "Sources/main.swift"
            )

            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            #expect(manifest.entries.contains { $0.relativePath == ".git/HEAD" })
            #expect(manifest.entries.contains { $0.relativePath == "current" && $0.kind == .symbolicLink })
            try await store.verify(manifest)

            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, to: fixture.restore)
            #expect(try String(contentsOf: fixture.restore.appending(path: "Sources/main.swift"), encoding: .utf8) == "hello")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.restore.appending(path: "current").path) == "Sources/main.swift")
        }
    }

    @Test("Content-addressed objects deduplicate identical files")
    func deduplication() async throws {
        try await withFixture { fixture in
            try fixture.write("same", to: "one.txt")
            try fixture.write("same", to: "two.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let hashes = manifest.entries.compactMap(\.contentHash)
            #expect(hashes.count == 2)
            #expect(Set(hashes).count == 1)
        }
    }

    @Test("Storage inside a repository is rejected")
    func rejectsRecursiveStorage() async throws {
        try await withFixture { fixture in
            let nestedStorage = fixture.repository.appending(path: "backup")
            let store = SnapshotStore(storageURL: nestedStorage)
            await #expect(throws: DurepoError.self) {
                try await store.createSnapshot(
                    repositoryURL: fixture.repository,
                    repositoryID: UUID(),
                    reason: .smokeTest
                )
            }
        }
    }

    @Test("Retention keeps only the newest snapshots")
    func retention() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage, retentionLimit: 3)
            for index in 0..<5 {
                try fixture.write("version \(index)", to: "file.txt")
                _ = try await store.createSnapshot(
                    repositoryURL: fixture.repository,
                    repositoryID: repositoryID,
                    reason: .manual
                )
            }
            let summaries = try await store.snapshotSummaries(repositoryID: repositoryID)
            #expect(summaries.count == 3)
            let manifestFiles = try FileManager.default.contentsOfDirectory(
                at: fixture.storage.appending(path: "manifests"),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            #expect(manifestFiles.count == 3)
        }
    }

    @Test("Mass deletion protects the last healthy snapshot and pauses retention")
    func anomalyProtectionPausesRetention() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            for index in 0..<100 { try fixture.write("file \(index)", to: "bulk/\(index).txt") }
            try fixture.write("ref: refs/heads/main\n", to: ".git/HEAD")
            let store = SnapshotStore(storageURL: fixture.storage, retentionLimit: 3)
            let healthy = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .initial
            )

            for index in 0..<60 {
                try FileManager.default.removeItem(at: fixture.repository.appending(path: "bulk/\(index).txt"))
            }
            let damaged = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .fileSystemEvent,
                detectAnomalies: true
            )

            var summaries = try await store.snapshotSummaries(repositoryID: repositoryID)
            #expect(summaries.first { $0.id == healthy.id }?.isProtected == true)
            #expect(summaries.first { $0.id == damaged.id }?.healthState == .anomalous)
            let alert = try #require(try await store.protectionAlerts().first)
            #expect(alert.kind == .massDeletion)
            #expect(alert.protectedSnapshotID == healthy.id)

            for version in 0..<5 {
                try fixture.write("version \(version)", to: "version.txt")
                _ = try await store.createSnapshot(
                    repositoryURL: fixture.repository,
                    repositoryID: repositoryID,
                    reason: .manual
                )
            }
            #expect(try await store.snapshotSummaries(repositoryID: repositoryID).count == 7)

            try await store.acknowledgeProtectionAlert(id: alert.id)
            _ = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .manual
            )
            summaries = try await store.snapshotSummaries(repositoryID: repositoryID)
            #expect(summaries.count == 4)
            #expect(summaries.contains { $0.id == healthy.id && $0.isProtected })
        }
    }

    @Test("Repository-unavailable alert protects the latest snapshot")
    func unavailableRepositoryProtectsLatestSnapshot() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("safe", to: "safe.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let healthy = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .initial
            )
            let alert = try await store.recordProtectionAlert(
                repositoryID: repositoryID,
                anomaly: RepositoryAnomaly(
                    kind: .repositoryUnavailable,
                    message: "Repository unavailable"
                )
            )

            #expect(alert.protectedSnapshotID == healthy.id)
            #expect(try await store.snapshotSummaries(repositoryID: repositoryID).first?.isProtected == true)
        }
    }

    @Test("Deleting snapshots can retain content-addressed objects")
    func snapshotDeletionKeepsObjects() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("recoverable", to: "file.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .manual
            )
            let hash = try #require(manifest.entries.first { $0.relativePath == "file.txt" }?.contentHash)
            let object = await store.objectURL(for: hash)

            let result = try await store.deleteSnapshots(repositoryID: repositoryID, mode: .keepObjects)

            #expect(result == SnapshotDeletionResult(deletedSnapshotCount: 1, deletedObjectCount: 0))
            #expect(FileManager.default.fileExists(atPath: object.path))
            #expect(try await store.snapshotSummaries(repositoryID: repositoryID).isEmpty)
        }
    }

    @Test("Permanent deletion removes only objects unreferenced by retained snapshots")
    func permanentSnapshotDeletionPreservesSharedObjects() async throws {
        try await withFixture { fixture in
            let repositoryA = UUID()
            let repositoryB = UUID()
            try fixture.write("shared", to: "shared.txt")
            try fixture.write("only-a", to: "unique.txt")
            let secondRepository = fixture.root.appending(path: "repository-b", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: secondRepository, withIntermediateDirectories: true)
            try Data("shared".utf8).write(to: secondRepository.appending(path: "shared.txt"))

            let store = SnapshotStore(storageURL: fixture.storage)
            let manifestA = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryA,
                reason: .manual
            )
            let manifestB = try await store.createSnapshot(
                repositoryURL: secondRepository,
                repositoryID: repositoryB,
                reason: .manual
            )
            let sharedHash = try #require(manifestA.entries.first { $0.relativePath == "shared.txt" }?.contentHash)
            let uniqueHash = try #require(manifestA.entries.first { $0.relativePath == "unique.txt" }?.contentHash)
            #expect(manifestB.entries.first?.contentHash == sharedHash)

            let result = try await store.deleteSnapshots(
                repositoryID: repositoryA,
                mode: .purgeUnreferencedObjects
            )

            #expect(result == SnapshotDeletionResult(deletedSnapshotCount: 1, deletedObjectCount: 1))
            #expect(!FileManager.default.fileExists(atPath: await store.objectURL(for: uniqueHash).path))
            #expect(FileManager.default.fileExists(atPath: await store.objectURL(for: sharedHash).path))
            try await store.verify(manifestB)
            #expect(try await store.snapshotSummaries(repositoryID: repositoryA).isEmpty)
            #expect(try await store.snapshotSummaries(repositoryID: repositoryB).count == 1)
        }
    }

    @Test("Events arriving during a snapshot remain pending")
    func eventJournalCommitBoundary() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage)
            var state = try await store.prepareMonitor(
                repositoryID: repositoryID,
                volumeID: "volume-a",
                rootID: "root-a"
            )
            #expect(state.hasPendingEvents)
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)

            try await store.recordEvent(repositoryID: repositoryID, eventID: 41, flags: 1, needsFullScan: false)
            let boundaryState = try await store.monitorState(repositoryID: repositoryID)
            let snapshotBoundary = try #require(boundaryState).lastSeenEventID
            try await store.recordEvent(repositoryID: repositoryID, eventID: 42, flags: 1, needsFullScan: true)
            state = try await store.commitEvents(repositoryID: repositoryID, through: snapshotBoundary)
            #expect(state.lastCommittedEventID == 41)
            #expect(state.lastSeenEventID == 42)
            #expect(state.hasPendingEvents)
            #expect(state.needsFullScan)
        }
    }

    @Test("Changing exclusion rules requests a full monitor scan")
    func exclusionRuleChangeRequestsFullScan() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.prepareMonitor(
                repositoryID: repositoryID,
                volumeID: "volume-a",
                rootID: "root-a"
            )
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)

            try await store.requireFullScan(repositoryID: repositoryID)

            let state = try #require(try await store.monitorState(repositoryID: repositoryID))
            #expect(state.hasPendingEvents)
            #expect(state.needsFullScan)
            let changes = try await store.pendingChangeSet(repositoryID: repositoryID, through: 0)
            #expect(changes.needsFullScan)
        }
    }

    @Test("Incremental snapshots reuse unchanged files and capture only dirty paths")
    func incrementalSnapshot() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("unchanged", to: "stable.txt")
            try fixture.write("before", to: "changed.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let initial = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .initial
            )
            let stableHash = try #require(initial.entries.first { $0.relativePath == "stable.txt" }?.contentHash)

            _ = try await store.prepareMonitor(repositoryID: repositoryID, volumeID: "volume-a", rootID: "root-a")
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
            #expect(Darwin.chmod(fixture.repository.appending(path: "stable.txt").path, 0) == 0)
            try fixture.write("after", to: "changed.txt")
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: 1,
                flags: 1,
                needsFullScan: false,
                changedPaths: ["changed.txt"]
            )
            let changes = try await store.pendingChangeSet(repositoryID: repositoryID, through: 1)
            #expect(changes == SnapshotChangeSet(changedPaths: ["changed.txt"], needsFullScan: false))

            let incremental = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .fileSystemEvent,
                changeSet: changes
            )
            #expect(incremental.entries.first { $0.relativePath == "stable.txt" }?.contentHash == stableHash)
            let changedHash = incremental.entries.first { $0.relativePath == "changed.txt" }?.contentHash
            #expect(changedHash != initial.entries.first { $0.relativePath == "changed.txt" }?.contentHash)
        }
    }

    @Test("Incremental directory deletion removes every descendant")
    func incrementalDirectoryDeletion() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("one", to: "bulk/one.txt")
            try fixture.write("two", to: "bulk/nested/two.txt")
            try fixture.write("keep", to: "keep.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.prepareMonitor(repositoryID: repositoryID, volumeID: "volume-a", rootID: "root-a")
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
            _ = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .initial
            )

            try FileManager.default.removeItem(at: fixture.repository.appending(path: "bulk"))
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: 2,
                flags: 1,
                needsFullScan: false,
                changedPaths: ["bulk"]
            )
            let changes = try await store.pendingChangeSet(repositoryID: repositoryID, through: 2)
            let afterDeletion = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .fileSystemEvent,
                changeSet: changes
            )
            #expect(!afterDeletion.entries.contains { $0.relativePath == "bulk" || $0.relativePath.hasPrefix("bulk/") })
            #expect(afterDeletion.entries.contains { $0.relativePath == "keep.txt" })
        }
    }

    @Test("Pending dirty paths survive a store restart")
    func dirtyPathPersistence() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.prepareMonitor(repositoryID: repositoryID, volumeID: "volume-a", rootID: "root-a")
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: 7,
                flags: 1,
                needsFullScan: false,
                changedPaths: ["Sources/main.swift", ".git/HEAD"]
            )

            let restarted = SnapshotStore(storageURL: fixture.storage)
            let changes = try await restarted.pendingChangeSet(repositoryID: repositoryID, through: 7)
            #expect(changes.changedPaths == [".git/HEAD", "Sources/main.swift"])
            #expect(!changes.needsFullScan)
        }
    }

    @Test("APFS-cloned objects survive source deletion")
    func cloneSurvivesSourceDeletion() async throws {
        try await withFixture { fixture in
            let contents = String(repeating: "0123456789abcdef", count: 65_536)
            try fixture.write(contents, to: "large.bin")
            let source = fixture.repository.appending(path: "large.bin")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let hash = try #require(manifest.entries.first { $0.relativePath == "large.bin" }?.contentHash)
            let object = await store.objectURL(for: hash)
            let sourceIdentifier = try source.resourceValues(forKeys: [.fileContentIdentifierKey]).fileContentIdentifier
            let objectIdentifier = try object.resourceValues(forKeys: [.fileContentIdentifierKey]).fileContentIdentifier
            #expect(String(describing: sourceIdentifier) == String(describing: objectIdentifier))

            try FileManager.default.removeItem(at: source)
            try await store.verify(manifest)
            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, to: fixture.restore)
            #expect(try String(contentsOf: fixture.restore.appending(path: "large.bin"), encoding: .utf8) == contents)
        }
    }

    @Test("Memory and streaming fallbacks preserve data without clone support")
    func copyFallbacks() async throws {
        try await withFixture { fixture in
            try fixture.write("small", to: "small.txt")
            try fixture.write(String(repeating: "large", count: 1_000), to: "large.txt")
            let store = SnapshotStore(
                storageURL: fixture.storage,
                maxConcurrentFileOperations: 4,
                smallFileThreshold: 16,
                cloneFilesWhenSupported: false
            )
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, to: fixture.restore)
            #expect(try String(contentsOf: fixture.restore.appending(path: "small.txt"), encoding: .utf8) == "small")
            #expect(try String(contentsOf: fixture.restore.appending(path: "large.txt"), encoding: .utf8) == String(repeating: "large", count: 1_000))
        }
    }

    @Test("Agent health errors persist until cleared")
    func agentHealthPersistence() async throws {
        try await withFixture { fixture in
            let store = SnapshotStore(storageURL: fixture.storage)
            let repositoryID = UUID()
            let recorded = try await store.recordAgentError(repositoryID: repositoryID, message: "snapshot failed")
            let loaded = try #require(try await store.agentHealth())
            #expect(loaded.errorID == recorded.errorID)
            #expect(loaded.message == recorded.message)
            #expect(abs(loaded.updatedAt.timeIntervalSince(recorded.updatedAt)) < 0.001)
            try await store.clearAgentError(repositoryID: repositoryID)
            #expect(try await store.agentHealth() == nil)
        }
    }

    @Test("Generated dependency and build directories are excluded")
    func generatedDirectoriesAreExcluded() async throws {
        try await withFixture { fixture in
            try fixture.write("source", to: "Sources/main.swift")
            try fixture.write("dependency", to: "node_modules/package/index.js")
            try fixture.write("generated", to: "web/dist/app.js")
            try fixture.write("cache", to: ".venv/lib/cache.py")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            #expect(manifest.entries.contains { $0.relativePath == "Sources/main.swift" })
            #expect(!manifest.entries.contains { $0.relativePath.hasPrefix("node_modules/") })
            #expect(!manifest.entries.contains { $0.relativePath.hasPrefix("web/dist/") })
            #expect(!manifest.entries.contains { $0.relativePath.hasPrefix(".venv/") })
        }
    }

    @Test("A repository-specific rule set replaces the global defaults")
    func repositorySpecificRulesReplaceDefaults() async throws {
        try await withFixture { fixture in
            try fixture.write("secret", to: "private.env")
            try fixture.write("dependency", to: "node_modules/package/index.js")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest,
                exclusionRules: ExclusionRuleSet(["*.env"])
            )

            #expect(!manifest.entries.contains { $0.relativePath == "private.env" })
            #expect(manifest.entries.contains { $0.relativePath == "node_modules/package/index.js" })
        }
    }

    @Test("Corrupt manifests are reported instead of silently hidden")
    func corruptManifestIsVisible() async throws {
        try await withFixture { fixture in
            let manifests = fixture.storage.appending(path: "manifests")
            try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
            let corrupt = manifests.appending(path: "\(UUID().uuidString).json")
            try Data("not-json".utf8).write(to: corrupt)
            let store = SnapshotStore(storageURL: fixture.storage)
            await #expect(throws: DurepoError.self) {
                try await store.prepare()
            }
        }
    }

    @Test("Stale temporary objects are removed on startup")
    func staleTemporaryCleanup() async throws {
        try await withFixture { fixture in
            let temporary = fixture.storage.appending(path: "temp")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let stale = temporary.appending(path: "stale.object")
            try Data("partial".utf8).write(to: stale)
            let store = SnapshotStore(storageURL: fixture.storage, staleTemporaryAge: 0)
            try await store.prepare()
            #expect(!FileManager.default.fileExists(atPath: stale.path))
        }
    }

    @Test("Git lock files are not restored")
    func gitLocksAreExcludedFromRestore() async throws {
        try await withFixture { fixture in
            try fixture.write("ref: refs/heads/main\n", to: ".git/HEAD")
            try fixture.write("locked", to: ".git/index.lock")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, to: fixture.restore)
            #expect(FileManager.default.fileExists(atPath: fixture.restore.appending(path: ".git/HEAD").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.restore.appending(path: ".git/index.lock").path))
        }
    }

    @Test("Snapshot differences are paged and classify added, modified, and removed paths")
    func snapshotDiffPagination() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("old", to: "modified.txt")
            try fixture.write("gone", to: "removed.txt")
            try fixture.write("stable", to: "stable.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )

            try fixture.write("new", to: "modified.txt")
            try FileManager.default.removeItem(at: fixture.repository.appending(path: "removed.txt"))
            try fixture.write("added", to: "added.txt")
            let second = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )

            let firstPage = try await store.snapshotDiff(id: second.id, offset: 0, limit: 2)
            #expect(firstPage.entries.count == 2)
            #expect(firstPage.hasMore)
            let secondPage = try await store.snapshotDiff(id: second.id, offset: 2, limit: 2)
            #expect(!secondPage.hasMore)
            let changes = Dictionary(uniqueKeysWithValues: (firstPage.entries + secondPage.entries).map {
                ($0.relativePath, $0.kind)
            })
            #expect(changes["added.txt"] == .added)
            #expect(changes["modified.txt"] == .modified)
            #expect(changes["removed.txt"] == .removed)

            let allFirstPage = try await store.snapshotEntries(id: second.id, offset: 0, limit: 2)
            let allSecondPage = try await store.snapshotEntries(id: second.id, offset: 2, limit: 2)
            #expect(allFirstPage.hasMore)
            #expect(!allSecondPage.hasMore)
            #expect(Set((allFirstPage.entries + allSecondPage.entries).map(\.relativePath)) == [
                "added.txt", "modified.txt", "stable.txt",
            ])
            #expect((allFirstPage.entries + allSecondPage.entries).allSatisfy { $0.kind == .unchanged })
        }
    }

    @Test("Selective restore includes a selected directory and its required ancestors")
    func selectiveRestore() async throws {
        try await withFixture { fixture in
            try fixture.write("one", to: "Sources/Nested/one.txt")
            try fixture.write("two", to: "Sources/two.txt")
            try fixture.write("skip", to: "Other/skip.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, selecting: ["Sources/Nested"], to: fixture.restore)

            #expect(FileManager.default.fileExists(atPath: fixture.restore.appending(path: "Sources/Nested/one.txt").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.restore.appending(path: "Sources/two.txt").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.restore.appending(path: "Other/skip.txt").path))
        }
    }

    @Test("In-place restore captures the current repository before an atomic replacement")
    func inPlaceRestore() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("snapshot", to: "tracked.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let target = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )
            try fixture.write("current", to: "tracked.txt")
            try fixture.write("new work", to: "uncommitted.txt")

            let result = try await store.restoreInPlace(
                snapshotID: target.id,
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                exclusionRules: .defaults
            )

            #expect(try String(contentsOf: fixture.repository.appending(path: "tracked.txt"), encoding: .utf8) == "snapshot")
            #expect(!FileManager.default.fileExists(atPath: fixture.repository.appending(path: "uncommitted.txt").path))
            #expect(result.preRestoreSnapshot.reason == .preRestore)
            #expect(result.preRestoreSnapshot.entries.contains { $0.relativePath == "uncommitted.txt" })
            #expect(try await store.hasRestoreSuppression(repositoryID: repositoryID))
            let restorer = SnapshotRestorer(store: store)
            let preRestoreDestination = fixture.root.appending(path: "pre-restore")
            _ = try await restorer.restore(result.preRestoreSnapshot, to: preRestoreDestination)
            #expect(try String(contentsOf: preRestoreDestination.appending(path: "tracked.txt"), encoding: .utf8) == "current")
        }
    }

    @Test("Hard links, sparse allocation, and extended attributes survive restore")
    func macMetadataRoundTrip() async throws {
        try await withFixture { fixture in
            try fixture.write("linked", to: "links/original.txt")
            try FileManager.default.linkItem(
                at: fixture.repository.appending(path: "links/original.txt"),
                to: fixture.repository.appending(path: "links/alias.txt")
            )
            let attributeValue = Data("metadata".utf8)
            let attributeResult = attributeValue.withUnsafeBytes { bytes in
                setxattr(
                    fixture.repository.appending(path: "links/original.txt").path,
                    "com.example.durepo-test",
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
            #expect(attributeResult == 0)
            let aclValue = "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read\n"
            let acl = try #require(acl_from_text(aclValue))
            #expect(acl_set_file(
                fixture.repository.appending(path: "links/original.txt").path,
                ACL_TYPE_EXTENDED,
                acl
            ) == 0)
            acl_free(UnsafeMutableRawPointer(acl))

            let sparse = fixture.repository.appending(path: "sparse.bin")
            let descriptor = Darwin.open(sparse.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            #expect(Darwin.ftruncate(descriptor, 8 * 1_048_576) == 0)
            Darwin.close(descriptor)

            let store = SnapshotStore(storageURL: fixture.storage)
            let repositoryID = UUID()
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )
            let sparseEntry = manifest.entries.first { $0.relativePath == "sparse.bin" }
            #expect((sparseEntry?.allocatedByteCount ?? .max) < (sparseEntry?.byteCount ?? 0))
            let originalEntry = try #require(manifest.entries.first { $0.relativePath == "links/original.txt" })
            let storedObjectURL = await store.objectURL(for: try #require(originalEntry.contentHash))
            let objectACL = try FileMetadata.aclText(at: storedObjectURL)
            #expect(objectACL?.contains("everyone:12:allow:read") != true)
            #expect(try FileMetadata.extendedAttributes(at: storedObjectURL, noFollow: false) == nil)

            let updatedAttributeValue = Data("updated".utf8)
            _ = updatedAttributeValue.withUnsafeBytes { bytes in
                setxattr(
                    fixture.repository.appending(path: "links/original.txt").path,
                    "com.example.durepo-test",
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
            let metadataOnlySnapshot = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )
            let metadataDiff = try await store.snapshotDiff(id: metadataOnlySnapshot.id)
            #expect(metadataDiff.entries.contains {
                $0.relativePath == "links/original.txt" && $0.kind == .modified
            })
            _ = try await SnapshotRestorer(store: store).restore(manifest, to: fixture.restore)

            let originalInfo = try fixture.restore.appending(path: "links/original.txt").lstatInfo()
            let aliasInfo = try fixture.restore.appending(path: "links/alias.txt").lstatInfo()
            #expect(originalInfo.st_ino == aliasInfo.st_ino)
            let attributes = try FileMetadata.extendedAttributes(
                at: fixture.restore.appending(path: "links/original.txt"),
                noFollow: false
            )
            #expect(attributes?.contains {
                $0.name == "com.example.durepo-test" && $0.value == attributeValue
            } == true)
            let restoredACL = try FileMetadata.aclText(
                at: fixture.restore.appending(path: "links/original.txt")
            )
            #expect(restoredACL?.contains("everyone:12:allow:read") == true)
            let restoredSparseInfo = try fixture.restore.appending(path: "sparse.bin").lstatInfo()
            #expect(Int64(restoredSparseInfo.st_blocks) * 512 < Int64(restoredSparseInfo.st_size))
        }
    }

    @Test("System-managed extended attributes are not snapshot metadata")
    func systemManagedExtendedAttributesAreExcluded() {
        #expect(!FileMetadata.shouldCaptureExtendedAttribute(named: "com.apple.macl"))
        #expect(!FileMetadata.shouldCaptureExtendedAttribute(named: "com.apple.provenance"))
        #expect(!FileMetadata.shouldCaptureExtendedAttribute(named: "com.apple.quarantine"))
        #expect(FileMetadata.shouldCaptureExtendedAttribute(named: "com.example.durepo-test"))
        #expect(FileMetadata.shouldIgnoreExtendedAttributeRemovalError(EPERM))
        #expect(FileMetadata.shouldIgnoreExtendedAttributeRemovalError(EACCES))
        #expect(!FileMetadata.shouldIgnoreExtendedAttributeRemovalError(EIO))
    }

    @Test("Integrity diagnostics find orphan objects and garbage collection reclaims them")
    func integrityAndGarbageCollection() async throws {
        try await withFixture { fixture in
            try fixture.write("orphan me", to: "file.txt")
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )
            _ = try await store.deleteSnapshots(repositoryID: repositoryID, mode: .keepObjects)

            let report = try await store.checkIntegrity()
            #expect(report.isHealthy)
            #expect(report.orphanObjectCount == 1)
            let collection = try await store.garbageCollect()
            #expect(collection.deletedObjectCount == 1)
            #expect(try await store.checkIntegrity().orphanObjectCount == 0)
        }
    }

    @Test("Capacity retention prunes old unprotected snapshots and their orphan objects")
    func capacityRetention() async throws {
        try await withFixture { fixture in
            let file = fixture.repository.appending(path: "large.bin")
            try Data(repeating: 0x41, count: 800_000).write(to: file)
            let repositoryID = UUID()
            let store = SnapshotStore(
                storageURL: fixture.storage,
                retentionLimit: 50,
                cloneFilesWhenSupported: false,
                maximumStorageByteCount: 1_048_576
            )
            _ = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )
            try Data(repeating: 0x42, count: 800_000).write(to: file)
            _ = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )

            #expect(try await store.snapshotSummaries(repositoryID: repositoryID).count == 1)
            let report = try await store.checkIntegrity()
            #expect(report.storedObjectCount == 1)
            #expect(report.orphanObjectCount == 0)
        }
    }

    @Test("Integrity diagnostics detect a corrupted content-addressed object")
    func corruptedObjectDiagnostics() async throws {
        try await withFixture { fixture in
            try fixture.write("trusted", to: "file.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let hash = try #require(manifest.entries.first { $0.kind == .file }?.contentHash)
            try Data("tampered".utf8).write(to: await store.objectURL(for: hash))

            let report = try await store.checkIntegrity()
            #expect(!report.isHealthy)
            #expect(report.issues.contains { $0.message.contains("hash mismatch") })
            await #expect(throws: DurepoError.self) { try await store.verify(manifest) }
        }
    }

    @Test("In-place restore refuses a repository with an active Git lock")
    func inPlaceRestoreGitLock() async throws {
        try await withFixture { fixture in
            try fixture.write("ref: refs/heads/main\n", to: ".git/HEAD")
            try fixture.write("locked", to: ".git/index.lock")
            try fixture.write("content", to: "file.txt")
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )
            await #expect(throws: DurepoError.self) {
                try await store.restoreInPlace(
                    snapshotID: manifest.id,
                    repositoryURL: fixture.repository,
                    repositoryID: repositoryID,
                    exclusionRules: .defaults
                )
            }
            #expect(try await store.snapshotSummaries(repositoryID: repositoryID).count == 1)
        }
    }

    @Test("A ten-thousand-file deletion is captured incrementally")
    func tenThousandFileDeletion() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let bulk = fixture.repository.appending(path: "bulk")
            try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
            for index in 0..<10_000 {
                let url = bulk.appending(path: "\(index).txt")
                #expect(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
            }
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.prepareMonitor(repositoryID: repositoryID, volumeID: "volume-a", rootID: "root-a")
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
            let initial = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )
            #expect(initial.fileCount == 10_000)
            let deletedPaths = (0..<10_000).map { "bulk/\($0).txt" }
            for path in deletedPaths {
                try FileManager.default.removeItem(at: fixture.repository.appending(path: path))
            }
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: 10_000,
                flags: 1,
                needsFullScan: false,
                changedPaths: deletedPaths
            )
            let changes = try await store.pendingChangeSet(repositoryID: repositoryID, through: 10_000)
            #expect(!changes.needsFullScan)
            let afterDeletion = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: initial.repositoryID,
                reason: .fileSystemEvent,
                changeSet: changes
            )
            #expect(afterDeletion.fileCount == 0)
        }
    }

    private func withFixture(
        _ operation: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await operation(fixture)
    }
}

private struct Fixture: Sendable {
    let root: URL
    let repository: URL
    let storage: URL
    let restore: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DurepoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = root.appending(path: "repository", directoryHint: .isDirectory)
        storage = root.appending(path: "storage", directoryHint: .isDirectory)
        restore = root.appending(path: "restore", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    }

    func write(_ contents: String, to relativePath: String) throws {
        let url = repository.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
