import Darwin
import FilaProtocol

/// A canonical directory, opened again at the moment something is done
/// inside it.
///
/// Every decision in this module is made about a string. `FilaPath.canonical`
/// resolves each symlink on the way to the parent, and the guard reads that
/// symlink-free spelling — but the syscall comes later and walks the string
/// again, and a process that can write any ancestor can swap a directory for a
/// link in between, sending a root delete or chown somewhere the guard never
/// saw. `O_NOFOLLOW_ANY` refuses a link anywhere in the path, so a swapped
/// ancestor fails the open with ELOOP instead; the `*at` calls made on the
/// descriptor afterwards never walk the path again.
///
/// The descriptor is opened for reading where that is allowed, and for search
/// alone where it is not: the `*at` calls need nothing more, and a folder may
/// grant write and search without read — root reads every folder, but the
/// in-process backend runs as the user. The ancestors need only search
/// permission either way.
@discardableResult
func filaWithDirectory<T>(_ canonicalPath: String, _ body: (Int32) throws -> T) throws -> T {
    let descriptor = try filaOpenDirectory(canonicalPath)
    defer { close(descriptor) }
    return try body(descriptor)
}

/// The descriptor `filaWithDirectory` lends, for a caller that closes it.
func filaOpenDirectory(_ canonicalPath: String) throws -> Int32 {
    let descriptor = Darwin.open(canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    if descriptor >= 0 {
        return descriptor
    }
    let code = Darwin.errno
    // `O_SEARCH` second, never first: a kernel older than it (before iOS 16)
    // may read the bit as nothing and ask for read again, or refuse it, and
    // either way the first refusal is the one to report.
    if code == EACCES {
        let searchOnly = Darwin.open(canonicalPath, O_SEARCH | O_NOFOLLOW_ANY | O_CLOEXEC)
        if searchOnly >= 0 {
            return searchOnly
        }
    }
    throw FilaFailure(errno: code, path: canonicalPath)
}

/// The directory a canonical path sits in and its name there, the way the
/// `*at` calls want them. The volume root is its own directory, named `.`.
func filaSplit(_ canonicalPath: String) -> (directory: String, name: String) {
    canonicalPath == "/" ? ("/", ".") : (FilaPath.directory(of: canonicalPath), FilaPath.name(of: canonicalPath))
}

/// `renameatx_np(2)` between two canonical paths, each side relative to its
/// pinned parent. Returns the errno, or zero, so callers can branch on EXDEV
/// and EEXIST the way they did on `renamex_np`.
func filaRename(_ source: String, to target: String, flags: UInt32) throws -> Int32 {
    let (sourceDirectory, sourceName) = filaSplit(source)
    let (targetDirectory, targetName) = filaSplit(target)
    return try filaWithDirectory(sourceDirectory) { from in
        try filaWithDirectory(targetDirectory) { to in
            renameatx_np(from, sourceName, to, targetName, flags) == 0 ? 0 : Darwin.errno
        }
    }
}
