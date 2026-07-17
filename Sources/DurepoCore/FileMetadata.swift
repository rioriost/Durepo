import Darwin
import Foundation

enum FileMetadata {
    private static let excludedAttributeNames: Set<String> = ["com.apple.provenance"]

    static func extendedAttributes(at url: URL, noFollow: Bool) throws -> [SnapshotExtendedAttribute]? {
        let options = noFollow ? XATTR_NOFOLLOW : 0
        let length = listxattr(url.path, nil, 0, options)
        guard length >= 0 else {
            if [ENOTSUP, EPERM, EACCES].contains(errno) { return nil }
            throw posixError()
        }
        guard length > 0 else { return nil }
        var names = [CChar](repeating: 0, count: length)
        guard listxattr(url.path, &names, names.count, options) == length else { throw posixError() }

        var result: [SnapshotExtendedAttribute] = []
        var start = 0
        while start < names.count {
            guard let end = names[start...].firstIndex(of: 0), end > start else { break }
            let name = String(decoding: names[start..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            if excludedAttributeNames.contains(name) {
                start = end + 1
                continue
            }
            let valueLength = getxattr(url.path, name, nil, 0, 0, options)
            if valueLength >= 0 {
                var data = Data(count: valueLength)
                let read = data.withUnsafeMutableBytes { bytes in
                    getxattr(url.path, name, bytes.baseAddress, valueLength, 0, options)
                }
                guard read == valueLength else { throw posixError() }
                result.append(SnapshotExtendedAttribute(name: name, value: data))
            } else if ![ENOATTR, ENOTSUP, EPERM, EACCES].contains(errno) {
                throw posixError()
            }
            start = end + 1
        }
        return result.isEmpty ? nil : result.sorted { $0.name < $1.name }
    }

    static func extendedAttributes(fileDescriptor: Int32) throws -> [SnapshotExtendedAttribute]? {
        let length = flistxattr(fileDescriptor, nil, 0, 0)
        guard length >= 0 else {
            if [ENOTSUP, EPERM, EACCES].contains(errno) { return nil }
            throw posixError()
        }
        guard length > 0 else { return nil }
        var names = [CChar](repeating: 0, count: length)
        guard flistxattr(fileDescriptor, &names, names.count, 0) == length else { throw posixError() }
        var result: [SnapshotExtendedAttribute] = []
        var start = 0
        while start < names.count {
            guard let end = names[start...].firstIndex(of: 0), end > start else { break }
            let name = String(decoding: names[start..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            if !excludedAttributeNames.contains(name) {
                let valueLength = fgetxattr(fileDescriptor, name, nil, 0, 0, 0)
                if valueLength >= 0 {
                    var data = Data(count: valueLength)
                    let read = data.withUnsafeMutableBytes { bytes in
                        fgetxattr(fileDescriptor, name, bytes.baseAddress, valueLength, 0, 0)
                    }
                    guard read == valueLength else { throw posixError() }
                    result.append(SnapshotExtendedAttribute(name: name, value: data))
                } else if ![ENOATTR, ENOTSUP, EPERM, EACCES].contains(errno) {
                    throw posixError()
                }
            }
            start = end + 1
        }
        return result.isEmpty ? nil : result.sorted { $0.name < $1.name }
    }

    static func aclText(at url: URL) throws -> String? {
        errno = 0
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            if [ENOENT, ENOTSUP, EPERM, EACCES].contains(errno) { return nil }
            throw posixError()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { throw posixError() }
        defer { acl_free(text) }
        let value = String(decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self),
            count: max(0, length)
        ), as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func aclText(fileDescriptor: Int32) throws -> String? {
        errno = 0
        guard let acl = acl_get_fd_np(fileDescriptor, ACL_TYPE_EXTENDED) else {
            if [ENOENT, ENOTSUP, EPERM, EACCES].contains(errno) { return nil }
            throw posixError()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { throw posixError() }
        defer { acl_free(text) }
        let value = String(decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self),
            count: max(0, length)
        ), as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func removeExtendedAttributes(at url: URL) throws {
        let length = listxattr(url.path, nil, 0, 0)
        guard length >= 0 else {
            if [ENOTSUP, EPERM, EACCES].contains(errno) { return }
            throw posixError()
        }
        guard length > 0 else { return }
        var names = [CChar](repeating: 0, count: length)
        guard listxattr(url.path, &names, names.count, 0) == length else { throw posixError() }
        var start = 0
        while start < names.count {
            guard let end = names[start...].firstIndex(of: 0), end > start else { break }
            let name = String(decoding: names[start..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            if removexattr(url.path, name, 0) != 0, errno != ENOATTR {
                throw posixError()
            }
            start = end + 1
        }
    }

    static func removeACL(at url: URL) throws {
        guard let emptyACL = acl_init(0) else { throw posixError() }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        if acl_set_file(url.path, ACL_TYPE_EXTENDED, emptyACL) != 0,
           ![ENOENT, ENOTSUP, EPERM, EACCES].contains(errno) {
            throw posixError()
        }
    }

    static func apply(_ entry: SnapshotEntry, to url: URL, noFollow: Bool = false) throws {
        let options = noFollow ? XATTR_NOFOLLOW : 0
        for attribute in entry.extendedAttributes ?? [] {
            let result = attribute.value.withUnsafeBytes { bytes in
                setxattr(url.path, attribute.name, bytes.baseAddress, bytes.count, 0, options)
            }
            guard result == 0 else { throw posixError() }
        }
        if let aclText = entry.aclText {
            guard let acl = acl_from_text(aclText) else { throw posixError() }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else { throw posixError() }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
