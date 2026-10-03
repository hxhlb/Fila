import Darwin
import FilaProtocol
import Foundation

// Creating a node applies its default attributes before returning it to the
// client. Moving a node preserves the metadata it already carries.

public extension FileOperations {
    /// Removes only an empty directory. The kernel's emptiness check and
    /// removal are one operation; a child created meanwhile is never deleted.
    func removeEmptyDirectory(at path: String) throws {
        let resolved = try resolveForDestruction(path)
        let (directory, name) = filaSplit(resolved)
        try filaWithDirectory(directory) { parent in
            try filaCheck(resolved) { unlinkat(parent, name, AT_REMOVEDIR) }
        }
    }

    /// Removes one node and never a tree: `rmdir(2)` when `directory`,
    /// `unlink(2)` otherwise.
    ///
    /// The caller says which kind it verified, and the kind is checked here
    /// with `lstat` before the call — `EISDIR` for a directory offered to
    /// `unlink`, `ENOTDIR` the other way — so a name whose kind changed
    /// between the caller's look and this call is left alone rather than
    /// removed under the wrong rule. Not left to the kernel: `unlink(2)`
    /// refuses a directory only for a process that is not the super-user,
    /// and this one is root. Neither call follows a symlink: removing a
    /// link removes the link, and a link to a directory is not a directory
    /// here. The guard is consulted like every other destruction;
    /// `overrideGuard` stops at the nodes with no recovery path, as
    /// `rename` does. Both calls are relative to the parent, opened again
    /// after the guard decided, so an ancestor swapped for a link in between
    /// cannot point them at a same-named node elsewhere.
    func removeNode(at path: String, directory: Bool, overrideGuard: Bool = false) throws {
        let resolved = try resolveForDestruction(path, overrideGuard: overrideGuard)
        let (parentPath, name) = filaSplit(resolved)
        try filaWithDirectory(parentPath) { parent in
            var metadata = stat()
            try filaCheck(resolved) { fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) }
            let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
            guard isDirectory == directory else {
                throw FilaFailure(errno: isDirectory ? EISDIR : ENOTDIR, path: resolved)
            }
            try filaCheck(resolved) { unlinkat(parent, name, directory ? AT_REMOVEDIR : 0) }
        }
    }

    /// mkdir, symlink, hardlink, or an empty regular file.
    ///
    /// An explicit `mode` keeps the caller's creation policy, such as a private
    /// workspace or an archive entry. Otherwise use the mobile/0777 defaults.
    /// Creation must stay in the writable root and fails with `EEXIST` rather
    /// than replacing anything.
    func create(_ template: NodeTemplate, at path: String, mode: mode_t? = nil) throws {
        let resolved = try resolveForWrite(path)
        switch template {
        case .directory:
            try filaCheck(resolved) { mkdir(resolved, mode ?? 0o700) }
        case .emptyFile:
            // O_EXCL, so "New File" can never truncate one that is already
            // there. A file manager that can destroy a file by creating one is
            // not a file manager.
            let descriptor = try filaCheck(resolved) {
                Darwin.open(resolved, O_CREAT | O_EXCL | O_WRONLY, mode ?? 0o600)
            }
            close(descriptor)
        case let .symbolicLink(target):
            try filaCheck(resolved) { symlink(target, resolved) }
        case let .hardLink(existing):
            // Canonicalised like every other path that reaches a syscall here:
            // a relative one would resolve against the daemon's own working
            // directory, which under launchd is `/`. A symlink target is the
            // one thing left alone, because a relative symlink is a real thing
            // a user means to make.
            // Linking changes the source inode too, so it cannot import an
            // outside inode under a writable name inside the root.
            let target = try resolveForWrite(existing)
            // No `AT_SYMLINK_FOLLOW`: a hard link to a symlink links the link,
            // which is the same rule the destructive operations follow.
            try filaCheck(resolved) { linkat(AT_FDCWD, target, AT_FDCWD, resolved, 0) }
            return // A hard link shares the source's existing metadata.
        }
        guard mode == nil else { return }
        do {
            try setAttributes(.newItemDefaults, at: resolved)
        } catch {
            // Only remove the node this call created. Never walk a directory
            // if another process has already put children inside it.
            if template == .directory {
                _ = rmdir(resolved)
            } else {
                _ = unlink(resolved)
            }
            throw error
        }
    }

    /// `renameat(2)` — the cheap move, and how the trash works.
    ///
    /// `exclusive` switches to `renamex_np(..., RENAME_EXCL)`, which fails with
    /// `EEXIST` rather than replacing what is at the destination. Callers that
    /// pick a free name and then rename into it want it: between the check and
    /// the rename another process can create that name, and POSIX `rename`
    /// destroys whatever it finds without a word. The kernel does the whole
    /// thing under one lock, so there is no window left to lose.
    ///
    /// The default is the POSIX behaviour, because replacing is what a move
    /// onto an existing file means. That default is only safe where the caller
    /// has already put the collision to the user — and not every caller does,
    /// so a caller that has not is a caller that should be passing `exclusive`.
    func rename(
        _ source: String,
        to destination: String,
        exclusive: Bool = false,
        overrideGuard: Bool = false,
    ) throws {
        let from = try resolveForDestruction(source, overrideGuard: overrideGuard)
        let to = try resolveForWrite(destination)

        // `rename(2)` replaces whatever is at the destination without a word,
        // so a destination that exists is as destructive as the source and gets
        // asked about the same way. An exclusive rename replaces nothing — it
        // fails instead — so there is nothing there for the guard to refuse.
        if !exclusive, filaExists(to) {
            _ = try resolveForDestruction(to, overrideGuard: overrideGuard)
            if try filaRemoveSecondName(from, of: to) {
                return
            }
        }
        // Between the two parents, opened again now, like a job's move.
        let failure = try filaRename(from, to: to, flags: exclusive ? UInt32(RENAME_EXCL) : 0)
        guard failure == 0 else { throw FilaFailure(errno: failure, path: from) }
    }
}

/// The replacing rename between two names of one file, done.
///
/// POSIX `rename(2)` succeeds and changes nothing when both names are links
/// to the same inode, so a Replace the user confirmed would report success
/// and leave both names. What it means is the destination name, holding the
/// same bytes, and the source name gone — which is `unlink` of the source,
/// and loses nothing, because the destination still names the file.
///
/// The same entry spelled another way is not two names: on a
/// case-insensitive volume that is a case-only rename, and the kernel does
/// it. Which spellings fold together is the volume's to say — APFS folds
/// pairs Foundation's comparison calls different — so the volume is asked:
/// a file with one link has one entry, and two lookups in one folder are one
/// entry when it reports the same stored name for both. Anything it cannot
/// answer is left to the kernel, whose worst case is the old no-op. Returns
/// false, having done nothing, unless the two names are distinct entries of
/// one non-directory inode.
private func filaRemoveSecondName(_ source: String, of target: String) throws -> Bool {
    let (sourceDirectory, sourceName) = filaSplit(source)
    let (targetDirectory, targetName) = filaSplit(target)
    return try filaWithDirectory(sourceDirectory) { from in
        try filaWithDirectory(targetDirectory) { into in
            var found = stat()
            var named = stat()
            guard fstatat(from, sourceName, &found, AT_SYMLINK_NOFOLLOW) == 0,
                  fstatat(into, targetName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  found.st_dev == named.st_dev, found.st_ino == named.st_ino,
                  found.st_mode & S_IFMT != S_IFDIR, found.st_nlink > 1
            else { return false }
            // One folder by identity, not by spelling.
            var fromFolder = stat()
            var intoFolder = stat()
            guard fstat(from, &fromFolder) == 0, fstat(into, &intoFolder) == 0 else { return false }
            if fromFolder.st_dev == intoFolder.st_dev, fromFolder.st_ino == intoFolder.st_ino {
                guard let stored = filaStoredName(sourceName, in: from),
                      let other = filaStoredName(targetName, in: into),
                      stored != other
                else { return false }
            }
            try filaCheck(source) { unlinkat(from, sourceName, 0) }
            return true
        }
    }
}

/// The name a folder's entry is stored under, whatever spelling found it —
/// `getattrlistat(2)`'s `ATTR_CMN_NAME`, without following a link. Nil when
/// the volume does not say.
private func filaStoredName(_ name: String, in directory: Int32) -> [UInt8]? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_NAME)
    // The length, the reference, and a name of up to `MAXPATHLEN` bytes.
    let header = MemoryLayout<UInt32>.size + MemoryLayout<attrreference_t>.size
    var buffer = [UInt8](repeating: 0, count: header + Int(MAXPATHLEN))
    return buffer.withUnsafeMutableBytes { raw -> [UInt8]? in
        guard let base = raw.baseAddress,
              getattrlistat(directory, name, &request, base, raw.count, UInt(FSOPT_NOFOLLOW)) == 0
        else { return nil }
        let reference = base + MemoryLayout<UInt32>.size
        let offset = Int(reference.loadUnaligned(fromByteOffset: 0, as: Int32.self))
        let length = Int(reference.loadUnaligned(fromByteOffset: MemoryLayout<Int32>.size, as: UInt32.self))
        let start = MemoryLayout<UInt32>.size + offset
        // The length counts the terminating NUL, which is not the name.
        guard length > 1, start >= header, start + length <= raw.count else { return nil }
        return Array(raw[start ..< start + length - 1])
    }
}
