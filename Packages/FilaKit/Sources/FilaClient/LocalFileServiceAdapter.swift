import Darwin
import FilaBackendKit
import FilaProtocol
import Foundation

/// The local file layer seen through the backend-neutral contract.
///
/// Paths are composed lexically under `rootPath`; every call then goes
/// through `LocalFileAccess`, so the guard, the canonicalisation and the
/// descriptor rules are the ones the daemon and the in-process service
/// already enforce. Nothing here opens a file by itself.
final class LocalFileServiceAdapter: FileService, @unchecked Sendable {
    private let access: any LocalFileAccess
    private let rootPath: String
    private let observation: DirectoryObservation

    /// Bytes per `read(2)`/`write(2)` in `copyContents`. Large enough that a
    /// multi-gigabyte copy is not a syscall storm, small enough that
    /// cancellation is answered promptly and the buffer is not worth noticing.
    static let chunkSize = 1 << 20

    init(access: any LocalFileAccess, rootPath: String, observation: DirectoryObservation) {
        self.access = access
        self.rootPath = rootPath
        self.observation = observation
    }

    func absolutePath(_ path: ServicePath) -> String {
        guard !path.isRoot else { return rootPath }
        let base = rootPath == "/" ? "" : rootPath
        return base + "/" + path.components.joined(separator: "/")
    }

    /// The inverse, lexically: nil for a path outside the root, or one that
    /// is not a path.
    func servicePath(forAbsolute absolute: String) -> ServicePath? {
        if rootPath == "/" {
            return try? ServicePath(absolute)
        }
        // By bytes: a String prefix compares Characters, and a child whose
        // name starts with a combining mark is one Character with its slash.
        guard absolute == rootPath || absolute.utf8.starts(with: (rootPath + "/").utf8) else { return nil }
        return try? ServicePath(String(decoding: absolute.utf8.dropFirst(rootPath.utf8.count), as: UTF8.self))
    }

    func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error> {
        let access = access
        let path = absolutePath(directory)
        // The folder itself, never the name: `details` resolves every
        // component but the last and `lstat`s that one, so a folder opened
        // through a link (`/etc`, `/var/jb`, `/tmp`) would be polled at the
        // link, whose time never moves. A last component of `.` is resolved
        // with the rest.
        let probe = path == "/" ? path : path + "/."
        return await observation.subscribe(path) {
            try await access.details(of: probe).node.modified
        }
    }

    func list(_ directory: ServicePath) async throws -> FileListing {
        let access = access
        let path = absolutePath(directory)
        return FileListing {
            let cursor = ListingCursor()
            return FileListing.Source(
                next: {
                    // Finished last time: the directory is already closed.
                    guard let current = cursor.next else { return nil }
                    let page = try await access.list(directory: path, cursor: current)
                    cursor.next = page.isFinal ? nil : page.cursor
                    return page.entries.map(FileEntry.init(node:))
                },
                close: {
                    // Only a listing abandoned between pages holds a cursor:
                    // a finished one released it with its last page, and one
                    // that never asked for a page has nothing to release.
                    guard let open = cursor.takeOpen() else { return }
                    try? await access.closeDirectory(cursor: open)
                },
            )
        }
    }

    func details(_ path: ServicePath) async throws -> FileEntry {
        try await FileEntry(node: access.details(of: absolutePath(path)).node)
    }

    func copyContents(
        of path: ServicePath,
        to descriptor: Int32,
        progress: @escaping @Sendable (TransferProgress) -> Void,
    ) async throws {
        let source = absolutePath(path)
        let input = try await access.open(source, flags: O_RDONLY)
        defer { close(input) }
        // What was opened, not what was named: `open` follows a symlink and
        // adds `O_NONBLOCK`, so a device or a fifo would come back as a
        // descriptor that never reaches end of file or reads `EAGAIN`. Only a
        // regular file has contents to copy, and its size is the honest
        // expectation — `details` would have measured the link.
        var status = stat()
        guard fstat(input, &status) == 0 else { throw FilaFailure(errno: errno, path: source) }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw FilaFailure(errno: status.st_mode & S_IFMT == S_IFDIR ? EISDIR : EINVAL, path: source)
        }
        let expected = Int64(status.st_size)
        try await DescriptorIO.blocking { isCancelled in
            try Self.pump(from: input, to: descriptor, expected: expected, isCancelled: isCancelled, progress: progress)
        }
    }

    /// Blocking: runs off the cooperative pool.
    private static func pump(
        from input: Int32,
        to output: Int32,
        expected: Int64,
        isCancelled: () -> Bool,
        progress: @escaping @Sendable (TransferProgress) -> Void,
    ) throws {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var completed: Int64 = 0
        while true {
            if isCancelled() {
                throw CancellationError()
            }
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw FilaFailure(errno: errno)
            }
            if count == 0 {
                break
            }
            var written = 0
            while written < count {
                if isCancelled() {
                    throw CancellationError()
                }
                let wrote = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }
                if wrote < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw FilaFailure(errno: errno)
                }
                // A write that moved nothing would loop here forever.
                guard wrote > 0 else { throw FilaFailure(errno: EIO) }
                written += wrote
            }
            completed += Int64(count)
            progress(TransferProgress(completed: completed, expected: expected))
        }
    }

    /// One iteration's place in a directory: zero before the first page,
    /// the daemon's cursor between pages, nil once finished or released.
    private final class ListingCursor: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64? = 0
        var next: UInt64? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }

        /// The cursor to close, if there is one, marking it released in the
        /// same step so a second release finds nothing.
        func takeOpen() -> UInt64? {
            lock.lock(); defer { lock.unlock() }
            defer { value = nil }
            guard let open = value, open != 0 else { return nil }
            return open
        }
    }
}

// MARK: - Writing

/// The destination side of the neutral contract, over the same local
/// access. Every write is the guarded one: a temporary beside the target,
/// published by an exclusive rename or the atomic replace, and a node
/// removed only one at a time.
extension LocalFileServiceAdapter: WritableFileService, DescriptorFileService {
    func openForReading(_ path: ServicePath) async throws -> Int32 {
        let source = absolutePath(path)
        // A transfer never dereferences a link: its plan skipped every one it
        // found. `O_NOFOLLOW` keeps that true for a file swapped for a link
        // since the plan — opened as root, the link would carry a file the
        // user could not read out of the device under the planned name.
        let descriptor = try await access.open(source, flags: O_RDONLY | O_NOFOLLOW)
        // As in `copyContents`: only a regular file has contents to carry.
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw FilaFailure(errno: code, path: source)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw FilaFailure(errno: status.st_mode & S_IFMT == S_IFDIR ? EISDIR : EINVAL, path: source)
        }
        return descriptor
    }

    func createDirectory(_ directory: ServicePath) async throws {
        let path = absolutePath(directory)
        do {
            try await access.create(.directory, at: path)
        } catch let failure as FilaFailure {
            throw Self.classify(failure, at: directory)
        }
    }

    func writeFile(
        from descriptor: Int32,
        size: Int64,
        to destination: ServicePath,
        policy: PublishPolicy,
        progress: @escaping @Sendable (TransferProgress) -> Void,
    ) async throws {
        let target = absolutePath(destination)
        let temporary = (target as NSString).deletingLastPathComponent + "/.fila-transfer-" + UUID().uuidString
        let output = try await access.open(temporary, flags: O_CREAT | O_EXCL | O_WRONLY, mode: 0o600)
        // Every failure after the temporary exists removes it — the write,
        // the attributes, the publication — so a folder the user is looking
        // at never keeps a `.fila-transfer-…` holding half the bytes.
        do {
            do {
                try await DescriptorIO.blocking { isCancelled in
                    try Self.pump(from: descriptor, to: output, expected: size, isCancelled: isCancelled, progress: progress)
                    // On disk before any publication: the plain rename that
                    // replaces a link does not sync the way `replaceItem`
                    // does, and a name must never come back from a power
                    // loss holding a short file.
                    while fsync(output) != 0 {
                        if errno != EINTR {
                            throw FilaFailure(errno: errno, path: temporary)
                        }
                    }
                }
            } catch {
                close(output)
                throw error
            }
            close(output)
            try Task.checkCancellation()
            switch policy {
            case .failIfExists:
                try await access.setAttributes(.newItemDefaults, at: temporary)
                try await access.rename(temporary, to: target, exclusive: true)
            case .replace:
                do {
                    // The atomic replace: the original's metadata is carried
                    // onto the new content, a missing original gets the
                    // defaults, and a directory at the name is refused.
                    try await access.replaceItem(at: target, withTemporary: temporary)
                } catch let failure as FilaFailure where failure.systemError == ELOOP {
                    // `replaceItem` refuses a link at the name, before it
                    // touches anything — a save to one would land nowhere.
                    // Replace replaces the name, as the copy job does: the
                    // link gives way to the file and is never written through,
                    // by the plain rename, which still asks the guard about the
                    // name it replaces. Asked only after that refusal, so an
                    // ordinary file costs no second round trip; an ELOOP with
                    // no link at the name (an ancestor swapped for one) stays
                    // the failure it was.
                    guard try await Self.isLink(target, access: access) else { throw failure }
                    try await access.setAttributes(.newItemDefaults, at: temporary)
                    try await access.rename(temporary, to: target, exclusive: false)
                }
            }
        } catch let failure as FilaFailure {
            try? await access.remove(temporary, directory: false)
            throw Self.classify(failure, at: destination)
        } catch {
            try? await access.remove(temporary, directory: false)
            throw error
        }
    }

    func removeFile(_ path: ServicePath) async throws {
        do {
            try await access.remove(absolutePath(path), directory: false)
        } catch let failure as FilaFailure {
            throw Self.classify(failure, at: path)
        }
    }

    func removeEmptyDirectory(_ path: ServicePath) async throws {
        do {
            try await access.remove(absolutePath(path), directory: true)
        } catch let failure as FilaFailure {
            throw Self.classify(failure, at: path)
        }
    }

    func move(_ source: ServicePath, to destination: ServicePath, policy: PublishPolicy) async throws {
        do {
            try await access.rename(absolutePath(source), to: absolutePath(destination), exclusive: policy == .failIfExists)
        } catch let failure as FilaFailure {
            // The syscall reports against the source name; what was missing
            // is the source, what was in the way is the destination.
            throw Self.classify(failure, at: failure.systemError == ENOENT ? source : destination)
        }
    }

    /// Whether a symbolic link is at `path`. Nothing there is not one.
    private static func isLink(_ path: String, access: any LocalFileAccess) async throws -> Bool {
        do {
            return try await access.details(of: path).node.kind == .symbolicLink
        } catch let failure as FilaFailure where failure.systemError == ENOENT {
            return false
        }
    }

    /// The refusals a transfer acts on, by errno; anything else stays the
    /// local failure it was, with its path and reason intact.
    private static func classify(_ failure: FilaFailure, at path: ServicePath) -> Error {
        switch failure.systemError {
        case EEXIST: WriteFailure.alreadyExists(path)
        case ENOENT: WriteFailure.notFound(path)
        case ENOTEMPTY, EISDIR: WriteFailure.notEmpty(path)
        default: failure
        }
    }
}

public extension FileEntry {
    /// A local node, with only what the neutral contract can promise about
    /// it. The full node stays available to local consumers.
    init(node: FileNode) {
        let kind: Kind
        switch node.kind {
        case .regular: kind = .file
        case .directory: kind = .directory
        case .symbolicLink:
            let resolved: Kind.ResolvedKind? = node.link?.resolvedKind.map { target in
                switch target {
                case .regular: .file
                case .directory: .directory
                default: .other
                }
            }
            kind = .symbolicLink(resolved: resolved)
        default: kind = .other
        }
        self.init(
            name: node.name,
            kind: kind,
            size: node.kind == .regular ? node.size : nil,
            modified: Date(timeIntervalSince1970: node.modified),
            isHidden: node.isHidden,
        )
    }
}
