import Darwin
import Foundation
import Synchronization

final class FileOperationLock: Sendable {
    private let descriptor: Mutex<Int32?>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    static func acquire(at url: URL) async throws -> FileOperationLock {
        try Task.checkCancellation()
        let lock: FileOperationLock = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try acquireSync(at: url) })
            }
        }
        do {
            try Task.checkCancellation()
            return lock
        } catch {
            lock.release()
            throw error
        }
    }

    static func acquireSync(at url: URL) throws -> FileOperationLock {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // flock belongs to the open file description, unlike process-owned lockf.
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        return FileOperationLock(descriptor: descriptor)
    }

    func release() {
        descriptor.withLock { descriptor in
            guard let openDescriptor = descriptor else { return }
            _ = flock(openDescriptor, LOCK_UN)
            Darwin.close(openDescriptor)
            descriptor = nil
        }
    }

    deinit { release() }
}
