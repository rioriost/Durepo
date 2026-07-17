import Darwin
import Foundation

public struct SnapshotChangeSet: Sendable, Equatable {
    public let changedPaths: [String]
    public let needsFullScan: Bool

    public init(changedPaths: [String], needsFullScan: Bool) {
        self.changedPaths = changedPaths
        self.needsFullScan = needsFullScan
    }
}

struct FileFingerprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusSeconds: Int64
    let statusNanoseconds: Int64

    init(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        statusSeconds: Int64,
        statusNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.statusSeconds = statusSeconds
        self.statusNanoseconds = statusNanoseconds
    }

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        statusSeconds = Int64(info.st_ctimespec.tv_sec)
        statusNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

struct IndexedSnapshotEntry: Sendable {
    let entry: SnapshotEntry
    let fingerprint: FileFingerprint?
}

enum SnapshotCaptureMethod: String, Sendable {
    case clone
    case memory
    case streaming
}

struct SnapshotCaptureResult: Sendable {
    let indexedEntry: IndexedSnapshotEntry
    let method: SnapshotCaptureMethod
}
