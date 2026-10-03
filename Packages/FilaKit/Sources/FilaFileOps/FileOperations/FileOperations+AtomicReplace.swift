import Darwin
import FilaProtocol
import Foundation

public extension FileOperations {
    /// Put a temporary the client has finished writing in place of `target`.
    ///
    /// Publish a completed regular file without truncating the old one. Flush
    /// the temporary before the atomic directory-entry swap; this does not
    /// promise durability against every storage or power failure.
    ///
    /// The known cost is taken knowingly: `rename` replaces the inode, so hard
    /// links to the old file keep the old content and a process holding it open
    /// never sees the new bytes. The alternative — `O_TRUNC` over the original
    /// — can destroy a file the user has no copy of.
    ///
    /// Alone among the destructive operations this takes no override. Every
    /// node the guard protects is a directory, so a replace of one is not a
    /// save the user meant to force — it is a client bug, and there is nothing
    /// to release.
    func replaceItem(at target: String, withTemporary temporary: String, permissions: mode_t? = nil) throws {
        let destination = try resolveForDestruction(target)
        // The temporary is *moved away* by the rename below, which is the act
        // the guard exists to forbid — and every protected node has an
        // unprotected sibling to name as the target. Guarding only the
        // destination would make this the way to move `/usr` somewhere.
        let source = try resolveForDestruction(temporary)

        // `rename(2)` is atomic within a directory and nowhere else. A caller
        // that put its temporary somewhere else got the one property this
        // operation exists for wrong, and has to find that out rather than
        // receive a copy that can be interrupted halfway.
        guard FilaPath.directory(of: source) == FilaPath.directory(of: destination) else {
            throw FilaFailure(code: .invalidRequest, systemError: EXDEV, path: temporary)
        }

        // Everything below is relative to the shared directory, held open, or
        // to the temporary itself: once the guard has decided, an ancestor
        // swapped for a link cannot point the chown, the chmod or the rename
        // at a same-named file somewhere else.
        let directory = try filaOpenDirectory(FilaPath.directory(of: destination))
        defer { close(directory) }
        let sourceName = FilaPath.name(of: source)
        let destinationName = FilaPath.name(of: destination)

        let descriptor = openat(directory, sourceName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw FilaFailure(errno: errno, path: source) }
        defer { close(descriptor) }
        var staged = stat()
        guard fstat(descriptor, &staged) == 0 else { throw FilaFailure(errno: errno, path: source) }
        guard staged.st_mode & S_IFMT == S_IFREG else { throw FilaFailure(errno: EINVAL, path: source) }

        var found = stat()
        let exists = fstatat(directory, destinationName, &found, AT_SYMLINK_NOFOLLOW) == 0
        if !exists, errno != ENOENT {
            throw FilaFailure(errno: errno, path: destination)
        }
        let original = exists ? found : nil
        if let original {
            // A directory at the name cannot be published over, and the
            // metadata copy below reaches that fact first: `copyfile(3)` from
            // a directory to a regular file fails with EINVAL, which reads as
            // a malformed request rather than as what is in the way. Report
            // the errno the `rename` itself would have produced — the one the
            // client turns into `notEmpty` — while both sides are untouched.
            guard original.st_mode & S_IFMT != S_IFDIR else {
                throw FilaFailure(errno: EISDIR, path: destination)
            }
            // A link is not the file to save. The rename below would put a
            // regular file in the link's place, carrying the link's 0755, and
            // leave the file it names with the old bytes: an edit that reports
            // success and lands nowhere. Callers save to the resolved target;
            // one that did not is told so, with what `O_NOFOLLOW` says.
            guard original.st_mode & S_IFMT != S_IFLNK else {
                throw FilaFailure(errno: ELOOP, path: destination)
            }
            // Metadata is written to the temporary before publication. It
            // must not share an inode with a name outside the writable root.
            _ = try resolveForWrite(source, changesInode: true)
            // ACLs and extended attributes through `copyfile(3)`, because a resource
            // fork is an extended attribute and can be megabytes — this streams
            // it and a hand-written loop would hold it.
            let existing = openat(directory, destinationName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard existing >= 0 else { throw FilaFailure(errno: errno, path: destination) }
            defer { close(existing) }
            try filaCheck(destination) {
                fcopyfile(existing, descriptor, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
            }
            // Owner before mode: chown clears setuid and setgid.
            try filaCheck(source) { fchown(descriptor, original.st_uid, original.st_gid) }
            try filaCheck(source) { fchmod(descriptor, original.st_mode & 0o7777) }
            // The access and modification times stay the temporary's own, the
            // time of this save: sync, backup and `make` decide by them, and
            // an edit that kept the old time could be skipped as unchanged.
            // The creation time is the original's, as a safe save on the Mac
            // keeps it. A filesystem with no creation time refuses it, and
            // that is no reason to lose the save.
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
            var created = original.st_birthtimespec
            _ = fsetattrlist(descriptor, &request, &created, MemoryLayout<timespec>.size, 0)
        } else if permissions == nil {
            _ = try resolveForWrite(source, changesInode: true)
            try filaApplyAttributes(.newItemDefaults, to: sourceName, in: directory, path: source, flags: nil)
        }

        if let permissions {
            _ = try resolveForWrite(source, changesInode: true)
            try filaCheck(source) { fchmod(descriptor, permissions) }
        }

        while fsync(descriptor) != 0 {
            if errno != EINTR {
                throw FilaFailure(errno: errno, path: source)
            }
        }
        try filaCheck(destination) { renameat(directory, sourceName, directory, destinationName) }

        // BSD flags go on afterwards, to the file at its new name: `uchg` on
        // the temporary would refuse the very rename that puts it in place. An
        // original that was already immutable fails the rename above with
        // EPERM, which is the errno the app needs to offer clearing the flag.
        if let original, original.st_flags != 0 {
            try filaCheck(destination) { fchflags(descriptor, original.st_flags) }
        }
    }
}
