import Darwin
import Foundation

/// Owns the endpoint and its persistent advisory lock until the read source
/// finishes cancellation. Other instances must leave an existing owner alone.
final class PointMCPSocketListener: Sendable {
    private struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    let fileDescriptor: Int32
    private let lockDescriptor: Int32
    private let socketURL: URL
    private let identity: Identity

    init(socketURL: URL, maximumClients: Int32) throws {
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Never unlink the lock file: replacing it would allow two owners to
        // lock different inodes for the same socket path.
        let lock = Darwin.open(
            socketURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard lock >= 0 else { throw Self.lastError() }
        var fd: Int32 = -1
        var boundIdentity: Identity?
        var succeeded = false
        defer {
            if !succeeded {
                if fd >= 0 { Darwin.close(fd) }
                if let boundIdentity { Self.unlink(socketURL, ifMatching: boundIdentity) }
                Darwin.close(lock)
            }
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Self.lastError() }

        var address = try Self.address(for: socketURL)
        var existing = stat()
        if lstat(socketURL.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else {
                throw POSIXError(.EEXIST)
            }
            // Also respect live listeners from versions predating the lock.
            try Self.requireStaleSocket(&address)
            guard Darwin.unlink(socketURL.path) == 0 else { throw Self.lastError() }
        } else if errno != ENOENT {
            throw Self.lastError()
        }

        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.lastError() }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Self.lastError() }
        var metadata = stat()
        guard lstat(socketURL.path, &metadata) == 0 else { throw Self.lastError() }
        let identity = Identity(device: metadata.st_dev, inode: metadata.st_ino)
        boundIdentity = identity
        guard Darwin.listen(fd, maximumClients) == 0,
              chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw Self.lastError()
        }

        fileDescriptor = fd
        lockDescriptor = lock
        self.socketURL = socketURL
        self.identity = identity
        succeeded = true
    }

    deinit {
        Darwin.close(fileDescriptor)
        Self.unlink(socketURL, ifMatching: identity)
        Darwin.close(lockDescriptor)
    }

    private static func address(for url: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                _ = memcpy(destination, source.baseAddress!, source.count)
            }
        }
        return address
    }

    private static func requireStaleSocket(_ address: inout sockaddr_un) throws {
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw lastError() }
        defer { Darwin.close(probe) }
        guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else { throw lastError() }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result != 0 else { throw POSIXError(.EADDRINUSE) }
        // A full backlog or a permissions failure is not a stale endpoint.
        guard errno == ECONNREFUSED || errno == ENOENT else { throw lastError() }
    }

    private static func unlink(_ url: URL, ifMatching identity: Identity) {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              Identity(device: metadata.st_dev, inode: metadata.st_ino) == identity else { return }
        Darwin.unlink(url.path)
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
