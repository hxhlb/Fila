import Darwin
import Dispatch
import FilaFileOps
import FilaProtocol
import Foundation

/// A `.compress` or an `.extract`, run to completion on the calling thread.
///
/// The one job that moves file bytes itself, which is why it never runs inside
/// `filad`: on a device it is the body of `fila-archive`, a process the daemon
/// spawns and signals, and in the app without a daemon it runs in-process.
/// What it opens and creates goes through `FileOperations` either way, and an
/// extracted member replaces nothing the guard would refuse.
///
/// Every path an archive supplies is joined to the destination in exactly one
/// place, `Placement`, which reaches it through descriptors rather than a path,
/// and nothing is created through a link.
public final class ArchiveJob: @unchecked Sendable {
    private let request: JobRequest
    private let options: ArchiveOptions
    private let operations: FileOperations
    private let cancellation = NSLock()
    private var cancelled = false

    public init(request: JobRequest, operations: FileOperations) {
        self.request = request
        options = request.archive ?? ArchiveOptions()
        self.operations = operations
    }

    /// Asks the job to stop at its next chunk. Safe from any thread.
    public func cancel() {
        cancellation.lock()
        cancelled = true
        cancellation.unlock()
    }

    public var isCancelled: Bool {
        cancellation.lock()
        defer { cancellation.unlock() }
        return cancelled
    }

    /// `note` carries what the outcome cannot: a member skipped for a reason
    /// the user should be able to find in the log.
    public func run(
        report: @escaping (JobProgress) -> Void,
        note: @escaping (String) -> Void = { _ in },
    ) -> FilaFailure {
        let progress = Progress(report: report)
        do {
            switch request.kind {
            case .compress: try compress(progress)
            case .extract: try extract(progress, note: note)
            default: throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
            }
            progress.flush()
            return FilaFailure(code: .success)
        } catch let failure as FilaFailure {
            return failure
        } catch let failure as FormatFailure {
            // libarchive's own message can quote the member's name.
            note(ArchivePath.displayName("libarchive: \(failure)"))
            return Self.outcome(for: failure, path: progress.currentPath)
        } catch {
            return FilaFailure(code: .operationFailed)
        }
    }

    private static func outcome(for failure: FormatFailure, path: String) -> FilaFailure {
        switch failure {
        case .cancelled: FilaFailure(code: .cancelled, path: path)
        case .wrongPassword: FilaFailure(code: .wrongPassword, path: path)
        case let .system(code): FilaFailure(errno: code, path: path)
        case .tooLarge: FilaFailure(code: .operationFailed, systemError: EFBIG, path: path)
        case .damaged, .unsupported, .notRecognised:
            FilaFailure(code: .operationFailed, systemError: EFTYPE, path: path)
        }
    }

    /// `path` is built only when the job has been cancelled: for a member it
    /// is a display name, and making one for every entry of a large archive
    /// would be a pass over every name for nothing.
    private func checkCancelled(_ path: @autoclosure () -> String) throws {
        if isCancelled {
            throw FilaFailure(code: .cancelled, path: path())
        }
    }

    // MARK: - Compress

    private func compress(_ progress: Progress) throws {
        guard let destination = request.destination else { throw FilaFailure(code: .invalidRequest) }
        let target = try FilaPath.canonical(destination)
        guard !filaExists(target) else { throw FilaFailure(code: .operationFailed, systemError: EEXIST, path: target) }

        let members = try collect()
        progress.total(bytes: members.reduce(0) { $0 + $1.byteCount }, items: Int64(members.count))

        // Written under a temporary name and renamed into place: a zip whose
        // central directory never got written is not a partial archive, it is
        // an unopenable one, and it must not appear under the real name.
        let temporary = FilaPath.join(FilaPath.directory(of: target), ".fila-archive-\(UUID().uuidString)")
        let descriptor = try operations.open(temporary, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        defer { close(descriptor) }
        do {
            try write(members, to: descriptor, progress: progress)
            try operations.setAttributes(.newItemDefaults, at: temporary)
            try synchronize(descriptor, path: temporary)
            try checkCancelled(target)
            try operations.rename(temporary, to: target, exclusive: true)
        } catch {
            unlink(temporary)
            throw error
        }
    }

    private struct Member {
        var name: String
        var path: String
        var kind: FileKind
        var mode: mode_t
        var modified: Date
        var byteCount: Int64
        var linkTarget: String?
    }

    /// The selection expanded into the entries the archive will hold, named
    /// relative to the directory the sources came from. Only a real directory
    /// is descended into: a symlink to one is stored as the link it is, which
    /// is also what stops a link back into `/private` from archiving the
    /// volume twice.
    private func collect() throws -> [Member] {
        var members: [Member] = []
        for source in request.sources {
            let path = try FilaPath.canonical(source)
            try append(path, as: FilaPath.name(of: path), into: &members)
        }
        return members
    }

    private func append(_ path: String, as name: String, into members: inout [Member]) throws {
        try checkCancelled(path)
        guard !ArchivePath.isFinderMetadata(name) else { return }
        var metadata = stat()
        try filaCheck(path) { lstat(path, &metadata) }
        let kind = FileKind(modeBits: metadata.st_mode)
        var linkTarget: String?
        if kind == .symbolicLink {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(path, &buffer, buffer.count - 1)
            guard length > 0 else { throw FilaFailure(errno: Darwin.errno, path: path) }
            linkTarget = String(cString: buffer)
        }
        guard members.count < ArchiveReader.maximumEntryCount else { throw FilaFailure(errno: E2BIG, path: path) }
        members.append(Member(
            name: name,
            path: path,
            kind: kind,
            // The archive records no owner, so every member reads back as
            // root's: a mobile file's setuid or setgid bit kept beside that
            // unpacks, under any extractor that restores ownership as root, as
            // a setuid-root program made from something the user could write.
            // The sticky bit grants nothing and stays.
            mode: metadata.st_mode & 0o1777,
            modified: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)),
            byteCount: kind == .regular ? Int64(metadata.st_size) : 0,
            linkTarget: linkTarget,
        ))
        guard kind == .directory else { return }
        guard let handle = opendir(path) else { throw FilaFailure(errno: Darwin.errno, path: path) }
        var names: [String] = []
        Darwin.errno = 0
        while let entry = readdir(handle) {
            let child = filaText(entry.pointee.d_name)
            if child != ".", child != ".." {
                names.append(child)
            }
        }
        let failed = Darwin.errno
        closedir(handle)
        guard failed == 0 else { throw FilaFailure(errno: failed, path: path) }
        for child in names.sorted() {
            try append(FilaPath.join(path, child), as: name + "/" + child, into: &members)
        }
    }

    private func write(_ members: [Member], to descriptor: Int32, progress: Progress) throws {
        let writer = try ArchiveWriter(
            descriptor: descriptor,
            format: options.format,
            zipCompression: options.zipCompression,
            encryption: options.encryption,
            password: options.password,
        )
        for member in members {
            try checkCancelled(member.path)
            progress.beginItem(member.path)
            switch member.kind {
            case .directory:
                try writer.addDirectory(member.name, mode: member.mode, modified: member.modified)
            case .symbolicLink:
                // A link with no readable target would go in with an empty
                // one, which is a member the extractor refuses.
                guard let target = member.linkTarget, !target.isEmpty else {
                    throw FilaFailure(code: .operationFailed, systemError: EINVAL, path: member.path)
                }
                try writer.addSymbolicLink(member.name, target: target, mode: member.mode, modified: member.modified)
            case .regular:
                let source = try operations.open(member.path, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW, mode: 0)
                defer { close(source) }
                try writer.addFile(member.name, from: source, mode: member.mode, modified: member.modified) { done, _ in
                    progress.fileProgress(done)
                    return !self.isCancelled
                }
            case .fifo, .socket, .blockDevice, .characterDevice, .unknown:
                throw FilaFailure(code: .operationFailed, systemError: EFTYPE, path: member.path)
            }
            progress.finishedItem(bytes: member.byteCount)
        }
        try writer.finish()
    }

    // MARK: - Extract

    /// One forward pass over the archive, creating only what was selected.
    ///
    /// Symbolic links are held back and created after everything else: an
    /// entry symlink's target is as attacker-controlled as its name, and a
    /// link created early is a link a later entry can be written *through*.
    /// Ordering alone is not enough (two link entries can nest), so
    /// `Placement` also refuses any path that passes through a link this run
    /// planted.
    private func extract(_ progress: Progress, note: (String) -> Void) throws {
        guard let source = request.sources.first, let destination = request.destination else {
            throw FilaFailure(code: .invalidRequest)
        }
        let archive = try FilaPath.canonical(source)
        let descriptor = try operations.open(archive, flags: O_RDONLY | O_NONBLOCK, mode: 0)
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw FilaFailure(errno: errno, path: archive) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw FilaFailure(errno: EINVAL, path: archive) }
        let reader = try ArchiveReader(
            descriptor: descriptor,
            name: FilaPath.name(of: archive),
            password: options.password,
        )
        let publication = try options.organizeExtraction == true
            ? ArchiveExtractionDestination(directory: destination, operations: operations) : nil
        defer {
            do { try publication?.discard() }
            catch { note("could not remove extraction temporary: \(error)") }
        }
        let placement = try publication.map {
            try Placement(operations: operations, directory: $0.workspace, path: $0.temporary, overwrite: false)
        } ?? Placement(operations: operations, creating: destination, overwrite: request.overwrite)

        // Matched by position, never by name — see `ArchiveSelection`.
        var wanted = options.members.map { selection in
            Dictionary(selection.map { ($0.index, $0.declaredPath) }, uniquingKeysWith: { first, _ in first })
        }
        progress.total(bytes: 0, items: Int64(wanted?.count ?? 0))

        var links: [ArchiveEntry] = []
        var index: Int64 = -1
        var remainingMetadata = ArchiveReader.maximumListingByteCount
        while wanted?.isEmpty != true, let entry = try reader.next() {
            index += 1
            guard index < ArchiveReader.maximumEntryCount else { throw FilaFailure(errno: E2BIG, path: archive) }
            let retainedBytes = entry.declaredPath.utf8.count
                + (entry.linkTarget?.utf8.count ?? 0)
                + (entry.hardLinkTarget?.utf8.count ?? 0)
            guard retainedBytes <= remainingMetadata else { throw FilaFailure(errno: E2BIG, path: archive) }
            remainingMetadata -= retainedBytes
            try checkCancelled(ArchivePath.displayName(entry.declaredPath))
            if wanted != nil {
                guard let listed = wanted?.removeValue(forKey: index) else { continue }
                // The listing and this pass are two reads of a file on a
                // filesystem the user is also using. A member that is no
                // longer the one they ticked is not theirs to receive.
                guard listed == entry.declaredPath else {
                    note("skipped “\(ArchivePath.displayName(entry.declaredPath))”: the archive changed after it was listed")
                    progress.finishedItem(bytes: 0)
                    continue
                }
            }
            guard !entry.isRootDirectory, !entry.isFinderMetadata else { continue }
            progress.beginItem(entry.declaredPath)
            // Their headers carry everything needed, so nothing is re-read.
            if entry.isSymbolicLink {
                links.append(entry)
                continue
            }
            try place(entry, with: placement, from: reader, progress: progress, note: note)
        }
        for entry in links {
            try checkCancelled(ArchivePath.displayName(entry.declaredPath))
            progress.beginItem(entry.declaredPath)
            try place(entry, with: placement, from: reader, progress: progress, note: note)
        }
        // Publication moves the top of the tree to another parent, which for a
        // directory needs that directory's own write bit when the mover is not
        // root, so a read-only top-level folder gets its mode once it has moved.
        let deferred = try placement.finish(deferringTopLevel: publication != nil)
        try publication?.publish(archiveName: archive, topLevelModes: deferred) { try self.checkCancelled(archive) }
    }

    private func place(
        _ entry: ArchiveEntry,
        with placement: Placement,
        from reader: ArchiveReader,
        progress: Progress,
        note: (String) -> Void,
    ) throws {
        do {
            try placement.place(entry, from: reader) { done, _ in
                progress.fileProgress(done)
                return !self.isCancelled
            }
        } catch let skipped as Placement.Skipped {
            // A member the archive cannot be trusted with is left out and said
            // so; a member the filesystem refused stops the job with its errno.
            note("skipped “\(ArchivePath.displayName(entry.declaredPath))”: \(skipped.reason)")
        }
        progress.finishedItem(bytes: entry.byteCount ?? 0)
    }

    // MARK: - Progress

    /// Throttled the way `JobTally` is: a large member reports thousands of
    /// times a second, and a bar cannot show more than a few.
    private final class Progress {
        private let report: (JobProgress) -> Void
        private var bytesTotal: Int64 = 0
        private var itemsTotal: Int64 = 0
        private var completedBytes: Int64 = 0
        private var currentFileBytes: Int64 = 0
        private var itemsDone: Int64 = 0
        private(set) var currentPath = ""
        private var lastReport = DispatchTime(uptimeNanoseconds: 1)

        init(report: @escaping (JobProgress) -> Void) {
            self.report = report
        }

        func total(bytes: Int64, items: Int64) {
            bytesTotal = bytes
            itemsTotal = items
        }

        /// The name goes out in every report, so only its display form is kept.
        func beginItem(_ path: String) {
            currentPath = ArchivePath.displayName(path)
            currentFileBytes = 0
            emit(throttled: true)
        }

        func fileProgress(_ bytes: Int64) {
            currentFileBytes = bytes
            emit(throttled: true)
        }

        func finishedItem(bytes: Int64) {
            completedBytes += bytes
            currentFileBytes = 0
            itemsDone += 1
            emit(throttled: true)
        }

        func flush() {
            emit(throttled: false)
        }

        private func emit(throttled: Bool) {
            let now = DispatchTime.now()
            if throttled, now.uptimeNanoseconds &- lastReport.uptimeNanoseconds < 100_000_000 {
                return
            }
            lastReport = now
            report(JobProgress(
                bytesDone: min(bytesTotal > 0 ? bytesTotal : .max, completedBytes + currentFileBytes),
                bytesTotal: bytesTotal,
                itemsDone: itemsDone,
                itemsTotal: itemsTotal,
                currentPath: currentPath,
            ))
        }
    }
}

/// One extraction run, and the only place an archive-supplied name is joined
/// to the directory the user chose.
///
/// A type rather than functions because the safety of a name depends on what
/// earlier entries in the same run already created: a symlink an archive
/// planted two entries ago is the thing a later entry gets written *through*,
/// and only something that remembers the run can see it.
///
/// Every member is reached from a descriptor on the destination, one
/// component at a time and never through a link, rather than through a path
/// string. On a device this runs as root into folders a less privileged
/// process can write, and a path the kernel resolves again at each call is
/// one whose components that process can swap between the check and the use.
private final class Placement {
    /// A member left out on purpose. The reason goes to the log; the job
    /// carries on, because the rest of the archive is still the user's.
    struct Skipped: Error {
        var reason: String
    }

    private let operations: FileOperations
    /// For the guard, for the longest path a member may get, and for
    /// messages. Nothing is opened through it.
    private let destination: String
    private let root: Int32
    private let overwrite: Bool
    /// New members belong to the user, as every new file does, and are given
    /// to them before they have a name anyone else can see.
    private let owner = AttributeChange.newItemDefaults

    /// Directories this run created, relative to the destination. Only these
    /// get an archive's mode: extracting something with a `Library/` entry
    /// into `/var/mobile` must not chmod the user's own `Library` to whatever
    /// the archive felt like, as root.
    private var created: Set<String> = []
    private var directoryPermissions: [String: mode_t] = [:]
    /// Relative paths this run created as symbolic links. Nothing may be
    /// written through one, including a later link entry.
    private var planted: Set<String> = []
    /// The directory the last member went into, still open: most members
    /// share a parent with the one before.
    private var recent: (relative: String, descriptor: Int32)?

    /// Into a directory the caller holds open, and keeps.
    init(operations: FileOperations, directory: Int32, path: String, overwrite: Bool) throws {
        root = try filaCheck(path) { fcntl(directory, F_DUPFD_CLOEXEC, 0) }
        self.operations = operations
        destination = path
        self.overwrite = overwrite
    }

    /// Into the destination the user named, made first when it is missing:
    /// once and not per entry, so a missing parent above it is one honest
    /// failure rather than one per member.
    convenience init(operations: FileOperations, creating destination: String, overwrite: Bool) throws {
        do {
            try operations.create(.directory, at: destination)
        } catch let failure as FilaFailure where failure.systemError == EEXIST {}
        let resolved = try FilaPath.resolve(destination)
        let descriptor = try operations.open(resolved, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW, mode: 0)
        defer { close(descriptor) }
        try self.init(operations: operations, directory: descriptor, path: resolved, overwrite: overwrite)
    }

    deinit {
        if let recent {
            close(recent.descriptor)
        }
        close(root)
    }

    func place(_ entry: ArchiveEntry, from reader: ArchiveReader, progress: @escaping ProgressHandler) throws {
        guard let relative = entry.relativePath else { throw Skipped(reason: "it points outside the destination") }
        guard entry.hardLinkTarget == nil else { throw Skipped(reason: "it is a hard link") }
        try refuseAPathThroughAPlantedLink(relative)
        // Descriptors reach deeper than `PATH_MAX`; nothing that names a file
        // by its path — the browser, delete, the guard — could reach it after.
        guard FilaPath.join(destination, relative).utf8.count < MAXPATHLEN else {
            throw failure(ENAMETOOLONG, relative)
        }

        switch entry.kind {
        case .directory:
            _ = try directory(relative)
            if created.contains(relative) {
                directoryPermissions[relative] = entry.permissions
            }

        case .symbolicLink:
            guard let linkTarget = entry.linkTarget, !linkTarget.isEmpty else {
                throw Skipped(reason: "it is a symbolic link with no target")
            }
            let (parent, name) = try self.parent(of: relative)
            guard try overwrite || existing(name, in: parent, relative) == nil
            else { throw Skipped(reason: "an item with that name already exists") }
            try link(to: linkTarget, named: name, in: parent, relative)
            planted.insert(relative)

        case .regular:
            let (parent, name) = try self.parent(of: relative)
            guard try overwrite || existing(name, in: parent, relative) == nil
            else { throw Skipped(reason: "an item with that name already exists") }
            try write(from: reader, named: name, in: parent, relative, permissions: entry.permissions, progress: progress)

        // A fifo, a socket or a device node is a thing a tar can carry and a
        // file manager has no business creating.
        case .fifo, .socket, .blockDevice, .characterDevice, .unknown:
            throw Skipped(reason: "it is not a file or a folder")
        }
    }

    /// Read-only directory modes are applied after their children, deepest
    /// first. Existing destination directories keep their own permissions.
    ///
    /// With `deferringTopLevel`, the modes of directories directly under the
    /// destination come back instead, for the caller to apply once it has
    /// moved them.
    func finish(deferringTopLevel: Bool = false) throws -> [String: mode_t] {
        var deferred: [String: mode_t] = [:]
        for (relative, mode) in directoryPermissions.sorted(by: { $0.key.count > $1.key.count }) {
            if deferringTopLevel, !relative.utf8.contains(UInt8(ascii: "/")) {
                deferred[relative] = mode
                continue
            }
            let descriptor = try directory(relative, creating: false)
            try check(relative) { fchmod(descriptor, mode) }
        }
        return deferred
    }

    /// The directory a member goes into, open, and the member's own name.
    private func parent(of relative: String) throws -> (descriptor: Int32, name: String) {
        var components = ArchivePath.components(of: relative)
        let name = try component(components.removeLast())
        return try (directory(components.joined(separator: "/")), name)
    }

    /// Every name an `*at` call is given is one component. `relativePath`
    /// already guarantees that; this is the second fence, at the call, because
    /// a name with a `/` byte in it goes wherever its `..` says.
    private func component(_ name: String) throws -> String {
        guard ArchivePath.isComponent(name) else { throw Skipped(reason: "it points outside the destination") }
        return name
    }

    private func refuseAPathThroughAPlantedLink(_ relative: String) throws {
        guard !planted.isEmpty else { return }
        var ancestor = ""
        for component in ArchivePath.components(of: relative).dropLast() {
            ancestor = ancestor.isEmpty ? String(component) : ancestor + "/" + component
            guard !planted.contains(ancestor) else {
                throw Skipped(reason: "it would be written through a symbolic link in the archive")
            }
        }
    }

    /// Streams one member into a temporary beside the target and renames it
    /// in, so a member that fails halfway never replaces what was there.
    private func write(
        from reader: ArchiveReader,
        named name: String,
        in parent: Int32,
        _ relative: String,
        permissions: mode_t,
        progress: @escaping ProgressHandler,
    ) throws {
        let temporary = ".fila-tmp-\(UUID().uuidString)"
        let descriptor = try check(relative) {
            openat(parent, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        defer { close(descriptor) }
        do {
            try reader.read(into: descriptor, progress: progress)
            // Owner before mode: chown clears setuid and setgid.
            try check(relative) { fchown(descriptor, owner.ownerID ?? geteuid(), owner.groupID ?? getegid()) }
            try check(relative) { fchmod(descriptor, permissions) }
            try synchronize(descriptor, path: ArchivePath.displayName(FilaPath.join(destination, relative)))
            try publish(temporary, as: name, in: parent, relative, file: descriptor)
        } catch {
            unlinkat(parent, temporary, 0)
            throw error
        }
    }

    /// A link is made under a temporary name too, so replacing one is the
    /// same rename that replaces a file rather than a create that cannot.
    private func link(to target: String, named name: String, in parent: Int32, _ relative: String) throws {
        let temporary = ".fila-tmp-\(UUID().uuidString)"
        try check(relative) { symlinkat(target, parent, temporary) }
        do {
            try check(relative) {
                fchownat(parent, temporary, owner.ownerID ?? geteuid(), owner.groupID ?? getegid(), AT_SYMLINK_NOFOLLOW)
            }
            try publish(temporary, as: name, in: parent, relative, file: nil)
        } catch {
            unlinkat(parent, temporary, 0)
            throw error
        }
    }

    /// Gives a finished temporary its name.
    ///
    /// Without `overwrite`, `RENAME_EXCL` refuses a name taken since the
    /// check before the member was read, and the member is skipped like any
    /// other collision. With it, the rename replaces what is there: never a
    /// folder, only after the guard, and a file keeps the owner, ACL,
    /// extended attributes and flags of the one it replaces, as a save does.
    private func publish(_ temporary: String, as name: String, in parent: Int32, _ relative: String, file: Int32?) throws {
        guard overwrite, let original = try existing(name, in: parent, relative) else {
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                guard errno == EEXIST else { throw failure(errno, relative) }
                throw Skipped(reason: "an item with that name already exists")
            }
            return
        }
        guard original.st_mode & S_IFMT != S_IFDIR else { throw failure(EISDIR, relative) }
        _ = try operations.resolveForDestruction(FilaPath.join(destination, relative))
        if let file, original.st_mode & S_IFMT == S_IFREG {
            let previous = try check(relative) { openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            defer { close(previous) }
            try check(relative) { fcopyfile(previous, file, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) }
            try check(relative) { fchown(file, original.st_uid, original.st_gid) }
        }
        try check(relative) { renameat(parent, temporary, parent, name) }
        // After the rename: `uchg` on the temporary would refuse it.
        if let file, original.st_flags != 0 {
            try check(relative) { fchflags(file, original.st_flags) }
        }
    }

    /// What is at `name` now, without following it; nil when nothing is.
    private func existing(_ name: String, in parent: Int32, _ relative: String) throws -> stat? {
        var metadata = stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else { throw failure(errno, relative) }
            return nil
        }
        return metadata
    }

    /// The directory `relative` names, opened from the destination one
    /// component at a time and made where missing — an archive is under no
    /// obligation to list its directories at all, let alone before the files
    /// inside them. The descriptor is borrowed until the next call.
    private func directory(_ relative: String, creating: Bool = true) throws -> Int32 {
        guard !relative.isEmpty else { return root }
        if let recent, recent.relative == relative {
            return recent.descriptor
        }
        var current = root
        var walked = ""
        do {
            for component in ArchivePath.components(of: relative) {
                walked = walked.isEmpty ? component : walked + "/" + component
                let next = try child(component, of: current, walked, creating: creating)
                if current != root {
                    close(current)
                }
                current = next
            }
        } catch {
            if current != root {
                close(current)
            }
            throw error
        }
        if let recent {
            close(recent.descriptor)
        }
        recent = (relative, current)
        return current
    }

    /// `mkdir(2)` answers `EEXIST` for a directory and for a link to one
    /// alike, and the difference is the whole attack: `O_NOFOLLOW` on the
    /// open is what tells them apart.
    private func child(_ name: String, of parent: Int32, _ relative: String, creating: Bool) throws -> Int32 {
        let name = try component(name)
        var made = false
        if creating {
            if mkdirat(parent, name, 0o755) == 0 {
                made = true
            } else if errno != EEXIST {
                throw failure(errno, relative)
            }
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            guard code == ENOTDIR || code == ELOOP else { throw failure(code, relative) }
            throw Skipped(reason: "“\(ArchivePath.displayName(relative))” already exists and is not a folder")
        }
        if made {
            created.insert(relative)
            guard fchown(descriptor, owner.ownerID ?? geteuid(), owner.groupID ?? getegid()) == 0 else {
                let code = errno
                close(descriptor)
                throw failure(code, relative)
            }
        }
        return descriptor
    }

    /// Failures name the member by its display form: the whole name may be
    /// longer than anything a report should carry.
    private func failure(_ code: Int32, _ relative: String) -> FilaFailure {
        FilaFailure(errno: code, path: ArchivePath.displayName(FilaPath.join(destination, relative)))
    }

    @discardableResult
    private func check(_ relative: String, _ body: () -> Int32) throws -> Int32 {
        let result = body()
        guard result >= 0 else { throw failure(errno, relative) }
        return result
    }
}

/// Flush file contents before the name becomes visible. A delayed write error
/// must leave the existing destination intact and remove only the temporary.
private func synchronize(_ descriptor: Int32, path: String) throws {
    while fsync(descriptor) != 0 {
        if errno != EINTR {
            throw FilaFailure(errno: errno, path: path)
        }
    }
}
