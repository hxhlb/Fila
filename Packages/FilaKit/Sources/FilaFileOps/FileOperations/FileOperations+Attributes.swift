import Darwin
import FilaProtocol
import Foundation

public extension FileOperations {
    /// Mode, owner, group, times, BSD flags and one extended attribute, applied
    /// to a path and — when the change says so — to everything beneath it.
    ///
    /// Metadata writes obey the same daemon write boundary as file contents.
    /// The destruction guard does not apply because the node remains in place.
    ///
    /// The outcome counts what a recursive change left alone beneath the node;
    /// see `AttributeOutcome`.
    @discardableResult
    func setAttributes(_ change: AttributeChange, at path: String) throws -> AttributeOutcome {
        let resolved = try resolveForWrite(path, changesInode: true)
        let (directory, name) = filaSplit(resolved)
        return try filaWithDirectory(directory) { parent in
            var metadata = stat()
            guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw FilaFailure(errno: Darwin.errno, path: resolved)
            }
            try filaApplyAttributes(change, to: name, in: parent, path: resolved, flags: change.systemFlags)

            // A recursive change on anything that is not a directory has already
            // been applied in full — including on a symlink, which is not followed
            // into whatever tree it points at.
            guard change.isRecursive, metadata.st_mode & S_IFMT == S_IFDIR else { return AttributeOutcome() }
            // The flags word the editor sends is this node's own with one bit
            // toggled. Stamping it on every descendant would unlock each locked
            // file and lock every other, so they take only the bits that changed
            // here, the way chflags(1) applies a set and a clear.
            let flags = change.systemFlags.map { word in
                FilaFlagChange(set: word & ~metadata.st_flags, clear: metadata.st_flags & ~word)
            }
            let skipped = try filaApplyAttributesBeneath(change, flags: flags, of: name, in: parent, path: resolved, operations: self)
            return AttributeOutcome(unchangedSharedFiles: skipped)
        }
    }
}

/// One node, named inside a directory the caller holds open, and every call is
/// the no-follow variant.
///
/// `FilaPath.canonical` resolves the parent and leaves the last component
/// alone, so the leaf may still be a symlink — and changing the mode of a
/// link's target when the user asked about the link is the same class of
/// mistake as deleting the wrong file. Relative to the descriptor, nothing
/// above the leaf is walked again either.
///
/// `path` names the node for errors and for the one call that has no `*at`
/// form. `flags` is the whole word this node ends up with, or nil to leave it.
func filaApplyAttributes(
    _ change: AttributeChange,
    to name: String,
    in directory: Int32,
    path: String,
    flags: UInt32?,
) throws {
    if change.ownerID != nil || change.groupID != nil {
        // `(uid_t)-1` is chown's "leave this one alone".
        let owner = change.ownerID ?? uid_t.max
        let group = change.groupID ?? gid_t.max
        try filaCheck(path) { fchownat(directory, name, owner, group, AT_SYMLINK_NOFOLLOW) }
    }

    // After the chown, which clears setuid and setgid.
    if let mode = change.mode {
        try filaCheck(path) { fchmodat(directory, name, mode, AT_SYMLINK_NOFOLLOW) }
    }

    if change.modified != nil || change.accessed != nil {
        // UTIME_OMIT leaves the other time exactly where it was.
        let unchanged = timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))
        let times = try [
            change.accessed.map(filaTimeSpec) ?? unchanged,
            change.modified.map(filaTimeSpec) ?? unchanged,
        ]
        try filaCheck(path) { utimensat(directory, name, times, AT_SYMLINK_NOFOLLOW) }
    }

    if let attribute = change.extendedAttribute {
        // Extended attributes have no `*at` form, so this one goes by path —
        // after proving the path still reaches the directory held open. What
        // remains is the gap between that proof and the call's own lookup.
        try filaWithDirectory(FilaPath.directory(of: path)) { current in
            var held = stat()
            var found = stat()
            guard fstat(directory, &held) == 0, fstat(current, &found) == 0,
                  held.st_dev == found.st_dev, held.st_ino == found.st_ino
            else {
                throw FilaFailure(errno: ENOENT, path: path)
            }
        }
        if let value = attribute.value {
            try filaCheck(path) {
                value.withUnsafeBytes {
                    setxattr(path, attribute.name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                }
            }
        } else {
            try filaCheck(path) { removexattr(path, attribute.name, XATTR_NOFOLLOW) }
        }
    }

    // Flags last. `uchg` and `schg` refuse every change above once they are
    // set, so setting them first would fail the rest of the same request.
    if let flags {
        try filaSetFlags(flags, of: name, in: directory, path: path)
    }
}

/// The whole BSD flags word of a node named inside a directory held open.
/// `fchflagsat` arrived in iOS 27; `setattrlistat` writes the same word,
/// relative to the descriptor and without following a link.
func filaSetFlags(_ flags: UInt32, of name: String, in directory: Int32, path: String) throws {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_FLAGS)
    var word = flags
    try filaCheck(path) {
        setattrlistat(directory, name, &request, &word, MemoryLayout<UInt32>.size, UInt32(FSOPT_NOFOLLOW))
    }
}

/// The BSD flags a recursive change turns on and off.
struct FilaFlagChange {
    var set: UInt32
    var clear: UInt32
}

/// A tree deeper than this is a hand-built loop, not a filesystem — and one
/// open descriptor per level is what makes the depth worth bounding at all.
private let filaMaximumWalkDepth = 256

/// The recursive variant: an explicit stack of open directories, one level at a
/// time.
///
/// Not a collected list of paths, and not `fts(3)`: both hold a whole directory
/// level at once, and a single directory on a device can carry 100k entries —
/// inside a daemon launchd kills at 6 MB. What is held here is one `DIR *` and
/// one path string per level of depth, and nothing whatever per entry.
///
/// Every level is opened relative to the one above it, and every change is
/// made relative to the level that holds the entry. The path strings name
/// entries in errors and are never resolved again: a directory renamed away
/// and replaced by a link mid-walk cannot send a root chown outside the tree.
///
/// Returns how many hard-linked files it left alone.
private func filaApplyAttributesBeneath(
    _ change: AttributeChange,
    flags: FilaFlagChange?,
    of root: String,
    in parent: Int32,
    path: String,
    operations: FileOperations,
) throws -> Int {
    var skipped = 0
    var stack: [(handle: UnsafeMutablePointer<DIR>, path: String)] = []
    defer { for level in stack {
        closedir(level.handle)
    } }

    func descend(into name: String, in directory: Int32, path: String) throws {
        guard stack.count < filaMaximumWalkDepth else {
            throw FilaFailure(code: .operationFailed, systemError: ELOOP, path: path)
        }
        // Real directories only. Following a link here would let one
        // `../../..` inside the tree turn a chown of a folder into a chown of
        // the device — and O_NOFOLLOW also refuses one swapped in since the
        // entry was stat'ed.
        let descriptor = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FilaFailure(errno: Darwin.errno, path: path) }
        guard let handle = fdopendir(descriptor) else {
            let code = Darwin.errno
            close(descriptor)
            throw FilaFailure(errno: code, path: path)
        }
        stack.append((handle, path))
    }

    try descend(into: root, in: parent, path: path)
    while let level = stack.last {
        // NULL is the end of this level or an I/O error on it, and skipping the
        // rest of a directory in silence is how half a tree ends up with the
        // old owner.
        Darwin.errno = 0
        guard let record = readdir(level.handle) else {
            let code = Darwin.errno
            guard code == 0 else { throw FilaFailure(errno: code, path: level.path) }
            closedir(level.handle)
            stack.removeLast()
            continue
        }
        let directory = dirfd(level.handle)
        guard let child = filaChild(record, in: directory) else { continue }
        let path = FilaPath.join(level.path, child.name)
        // A writable root refuses any shared inode outright, as every other
        // write under it does: its other name may be outside the root.
        try operations.requireUnshared(child.metadata, path: path)
        // A file with a second name is not only in this tree. Anyone who can
        // write a folder can hard-link a root-owned file on the same volume
        // into it, and a recursive chown run as root would hand that file over
        // through the name the user never saw. The node the user named is
        // changed as asked; a shared one found beneath it is left alone and
        // counted.
        if child.metadata.st_mode & S_IFMT != S_IFDIR, child.metadata.st_nlink > 1 {
            skipped += 1
            continue
        }

        let word = flags.map { (child.metadata.st_flags | $0.set) & ~$0.clear }
        try filaApplyAttributes(
            change,
            to: child.name,
            in: directory,
            path: path,
            flags: word == child.metadata.st_flags ? nil : word,
        )
        if child.metadata.st_mode & S_IFMT == S_IFDIR {
            try descend(into: child.name, in: directory, path: path)
        }
    }
    return skipped
}

/// A time from the wire. NaN, an infinity or anything past `time_t` would
/// trap in the conversion and take the daemon down with it, so it is refused.
func filaTimeSpec(_ seconds: Double) throws -> timespec {
    let whole = seconds.rounded(.down)
    guard let second = __darwin_time_t(exactly: whole) else {
        throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
    }
    return timespec(tv_sec: second, tv_nsec: Int((seconds - whole) * 1_000_000_000))
}

func filaTimeValue(_ seconds: Double) -> timeval {
    let whole = seconds.rounded(.down)
    return timeval(
        tv_sec: __darwin_time_t(whole),
        tv_usec: __darwin_suseconds_t((seconds - whole) * 1_000_000),
    )
}
