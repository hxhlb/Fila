import Darwin
import FilaFileOps
import FilaProtocol
import Foundation

/// A private sibling workspace, published only after every member succeeds.
/// A single top-level item keeps its own name; multiple items share one folder.
///
/// The folder and the workspace are held open. Members are placed relative to
/// the workspace descriptor, and its name in the folder — which anything that
/// can write the folder can rename or replace — is used only to publish it and
/// to discard it, each time after checking that it still names this workspace.
final class ArchiveExtractionDestination {
    let workspace: Int32
    /// For messages and for the longest path a member may get.
    let temporary: String
    private let directory: String
    private let folder: Int32
    private let name: String
    private let operations: FileOperations
    /// The workspace itself was renamed into place, so its old name is no
    /// longer this run's to remove.
    private var published = false

    init(directory: String, operations: FileOperations) throws {
        let directory = try FilaPath.resolve(directory)
        let name = ".fila-extract-\(UUID().uuidString)"
        let temporary = FilaPath.join(directory, name)
        let folder = try operations.open(directory, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW, mode: 0)
        let workspace: Int32
        do {
            // Made by path, because `create` is where the writable root is
            // enforced; found again through the held folder, so a path that
            // has since moved elsewhere finds nothing rather than another one.
            try operations.create(.directory, at: temporary, mode: 0o700)
        } catch {
            close(folder)
            throw error
        }
        do {
            workspace = try filaCheck(temporary) { openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        } catch {
            unlinkat(folder, name, AT_REMOVEDIR)
            close(folder)
            throw error
        }
        // Between the two calls the name could have been given to another
        // directory; one this process did not make is not a private workspace.
        // A volume that ignores ownership reports the same owner for every
        // node, so there the owner proves nothing and is not asked.
        var metadata = stat()
        var volume = statfs()
        guard fstat(workspace, &metadata) == 0, fstatfs(workspace, &volume) == 0,
              volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 || metadata.st_uid == geteuid()
        else {
            close(workspace)
            close(folder)
            throw FilaFailure(errno: EPERM, path: temporary)
        }
        self.directory = directory
        self.name = name
        self.temporary = temporary
        self.folder = folder
        self.workspace = workspace
        self.operations = operations
    }

    deinit {
        close(workspace)
        close(folder)
    }

    /// `topLevelModes` are the archive's modes for directories directly in
    /// the workspace. The one that moves gets its mode after the move: moving
    /// a directory to another parent needs its own write bit, which a
    /// read-only folder lacks for anyone but root.
    func publish(archiveName: String, topLevelModes: [String: mode_t], checkCancelled: () throws -> Void) throws {
        let entries = try topLevelEntries(limit: 2)
        guard !entries.isEmpty else { return }
        let single = entries.count == 1 ? entries[0] : nil
        let name = single?.name ?? ArchivePath.extractionFolderName(for: archiveName)
        let isDirectory = single?.isDirectory ?? true
        let suffix = isDirectory ? "" : (name as NSString).pathExtension
        let stem = suffix.isEmpty ? name : (name as NSString).deletingPathExtension

        // Held across the rename, so the mode lands on what moved rather than
        // on whatever has its new name by then.
        var moved: Int32 = -1
        defer {
            if moved >= 0 {
                close(moved)
            }
        }
        if let single {
            if single.isDirectory, topLevelModes[single.name] != nil {
                moved = try filaCheck(temporary) {
                    openat(workspace, single.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
        } else {
            for (entry, mode) in topLevelModes {
                let descriptor = try filaCheck(temporary) {
                    openat(workspace, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                defer { close(descriptor) }
                try filaCheck(temporary) { fchmod(descriptor, mode) }
            }
            guard try namesWorkspace() else { throw FilaFailure(errno: ENOENT, path: temporary) }
        }

        for index in 1 ... Int.max {
            try checkCancelled()
            let base = stem.isEmpty ? "Archive" : stem
            let numbered = index == 1 ? base : "\(base) \(index)"
            let candidate = numbered + (suffix.isEmpty ? "" : "." + suffix)
            let published = FilaPath.join(directory, candidate)
            let renamed = single.map { renameatx_np(workspace, $0.name, folder, candidate, UInt32(RENAME_EXCL)) }
                ?? renameatx_np(folder, self.name, folder, candidate, UInt32(RENAME_EXCL))
            guard renamed == 0 else {
                guard Darwin.errno == EEXIST else { throw FilaFailure(errno: Darwin.errno, path: published) }
                continue
            }
            self.published = single == nil
            if moved >= 0, let single, let mode = topLevelModes[single.name] {
                try filaCheck(published) { fchmod(moved, mode) }
            } else if single == nil {
                // The wrapper is a new folder of the user's, owned like one —
                // only once it has its name: until then a cancel or a failed
                // rename removes it, and the less privileged user must not be
                // able to write into a tree while it is being removed.
                let defaults = AttributeChange.newItemDefaults
                try filaCheck(published) { fchown(workspace, defaults.ownerID ?? geteuid(), defaults.groupID ?? getegid()) }
                try filaCheck(published) { fchmod(workspace, defaults.mode ?? 0o777) }
            }
            return
        }
        throw FilaFailure(errno: EEXIST, path: directory)
    }

    func discard() throws {
        guard !published, try namesWorkspace() else { return }
        try operations.discardTemporary(temporary)
    }

    /// Whether the workspace's name in the folder is still this workspace.
    private func namesWorkspace() throws -> Bool {
        var held = stat()
        var named = stat()
        try filaCheck(temporary) { fstat(workspace, &held) }
        guard fstatat(folder, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard Darwin.errno == ENOENT else { throw FilaFailure(errno: Darwin.errno, path: temporary) }
            return false
        }
        return named.st_dev == held.st_dev && named.st_ino == held.st_ino
    }

    /// Up to `limit` of the workspace's entries, read through its descriptor.
    private func topLevelEntries(limit: Int) throws -> [(name: String, isDirectory: Bool)] {
        let descriptor = try filaCheck(temporary) { fcntl(workspace, F_DUPFD_CLOEXEC, 0) }
        guard let handle = fdopendir(descriptor) else {
            let code = Darwin.errno
            close(descriptor)
            throw FilaFailure(errno: code, path: temporary)
        }
        defer { closedir(handle) }
        rewinddir(handle)
        var entries: [(name: String, isDirectory: Bool)] = []
        while entries.count < limit {
            Darwin.errno = 0
            guard let record = readdir(handle) else {
                let code = Darwin.errno
                guard code == 0 else { throw FilaFailure(errno: code, path: temporary) }
                break
            }
            let entry = filaText(record.pointee.d_name)
            guard entry != ".", entry != ".." else { continue }
            var metadata = stat()
            try filaCheck(temporary) { fstatat(workspace, entry, &metadata, AT_SYMLINK_NOFOLLOW) }
            entries.append((entry, metadata.st_mode & S_IFMT == S_IFDIR))
        }
        return entries
    }
}
