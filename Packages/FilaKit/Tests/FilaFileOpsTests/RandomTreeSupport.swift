import CRemoveFile
import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation

// Shared fixtures for the random-tree, race and cross-volume suites. Everything
// lives under a fresh directory in /private/tmp and is removed — flags cleared
// first — on deinit.

struct HuntRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Clears BSD flags and restores owner access below `path`, so removefile can
/// take a tree a test made immutable or unreadable.
func huntUnlock(_ path: String) {
    var info = stat()
    guard lstat(path, &info) == 0 else { return }
    if info.st_flags != 0 { _ = lchflags(path, 0) }
    guard info.st_mode & S_IFMT == S_IFDIR else { return }
    _ = chmod(path, (info.st_mode & 0o7777) | S_IRWXU)
    guard let handle = opendir(path) else { return }
    defer { closedir(handle) }
    while let entry = readdir(handle) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if name == "." || name == ".." { continue }
        huntUnlock(path + "/" + name)
    }
}

final class HuntScratch {
    let root: String
    private var mounts: [String] = []

    init(_ label: String = "hunt") {
        let created = "/private/tmp/fila-tests-\(label)-\(getpid())-\(UInt32.random(in: 0 ..< .max))"
        precondition(mkdir(created, 0o755) == 0, "scratch: \(String(cString: strerror(errno)))")
        // /private/tmp is root:wheel, and a new node takes its directory's
        // group. A user outside wheel cannot give that group to a copy on
        // another volume, so start from the user's own group.
        _ = chown(created, getuid(), getgid())
        root = (try? FilaPath.resolve(created)) ?? created
    }

    deinit {
        for mount in mounts.reversed() { huntDetach(mount) }
        huntUnlock(root)
        removefile(root, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func directory(_ relative: String, mode: mode_t = 0o755) -> String {
        var built = root
        // Bytes, not Characters: "/" followed by U+0301 is one Character.
        for component in relative.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true) {
            built += "/" + String(decoding: component, as: UTF8.self)
            precondition(mkdir(built, mode) == 0 || errno == EEXIST, "mkdir \(built): \(String(cString: strerror(errno)))")
        }
        return built
    }

    @discardableResult
    func file(_ relative: String, bytes: [UInt8], mode: mode_t = 0o644) -> String {
        let path = path(relative)
        let fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, mode)
        precondition(fd >= 0, "open \(path): \(String(cString: strerror(errno)))")
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        return path
    }

    @discardableResult
    func file(_ relative: String, _ text: String = "fila", mode: mode_t = 0o644) -> String {
        file(relative, bytes: Array(text.utf8), mode: mode)
    }

    /// A small APFS volume mounted inside this scratch, or nil when the host
    /// refuses (no hdiutil, sandboxed runner). Detached on deinit.
    func mountVolume(_ name: String, megabytes: Int) -> String? {
        let image = path(name + ".sparseimage")
        let mountPoint = directory(name + "-mnt")
        let create = huntRun("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(megabytes)m", "-fs", "APFS", "-type", "SPARSE", "-volname", "FilaTests\(name)", path(name)])
        guard create == 0 else { return nil }
        let attach = huntRun("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-owners", "on", "-mountpoint", mountPoint, image])
        guard attach == 0 else { return nil }
        mounts.append(mountPoint)
        return (try? FilaPath.resolve(mountPoint)) ?? mountPoint
    }
}

/// Whether this host attaches a disk image at all, probed once with a small
/// one. A sandboxed runner or a container cannot, and a suite that needs a
/// second volume is skipped there rather than failed.
let huntCanAttachVolumes: Bool = {
    let probe = HuntScratch("attach-probe")
    return probe.mountVolume("probe", megabytes: 20) != nil
}()

@discardableResult
func huntRun(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

func huntDetach(_ mountPoint: String) {
    huntUnlock(mountPoint)
    if huntRun("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint]) != 0 {
        huntRun("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint])
    }
}

// MARK: - Snapshots

struct HuntEntry: Equatable, CustomStringConvertible {
    var kind: mode_t
    var mode: mode_t
    var uid: uid_t
    var gid: gid_t
    var flags: UInt32
    var mtime: Int
    var content: [UInt8]?
    var linkTarget: String?
    var xattrs: [String: [UInt8]]
    var acl: String?

    var description: String {
        "kind=\(String(kind, radix: 8)) mode=\(String(mode, radix: 8)) flags=\(String(flags, radix: 16)) size=\(content?.count ?? -1) link=\(linkTarget ?? "-") xattrs=\(xattrs.keys.sorted()) acl=\(acl != nil)"
    }
}

/// Flags a copy is expected to carry. UF_COMPRESSED and the SF_ flags are
/// filesystem- or root-owned and excluded.
let huntComparableFlags = UInt32(UF_NODUMP | UF_IMMUTABLE | UF_APPEND | UF_HIDDEN)

func huntXattrs(_ path: String, ignoring: Set<String>) -> [String: [UInt8]] {
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [:] }
    var names = [CChar](repeating: 0, count: size)
    let written = names.withUnsafeMutableBufferPointer { listxattr(path, $0.baseAddress, size, XATTR_NOFOLLOW) }
    guard written > 0 else { return [:] }
    var result: [String: [UInt8]] = [:]
    var start = 0
    for index in 0 ..< written where names[index] == 0 {
        defer { start = index + 1 }
        guard index > start else { continue }
        let name = String(cString: Array(names[start ..< index]) + [0])
        if ignoring.contains(name) { continue }
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { continue }
        var value = [UInt8](repeating: 0, count: length)
        let read = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        result[name] = Array(value.prefix(max(0, read)))
    }
    return result
}

func huntACL(_ path: String) -> String? {
    guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard let text = acl_to_text(acl, nil) else { return nil }
    defer { acl_free(text) }
    return String(cString: text)
}

func huntReadAll(_ path: String) -> [UInt8]? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count <= 0 { break }
        bytes += buffer[0 ..< count]
    }
    return bytes
}

/// relative path -> entry, for `root` and everything beneath it. The root is "".
func huntSnapshot(_ root: String, ignoringXattrs: Set<String> = [], includeRootFlags: Bool = true) -> [String: HuntEntry] {
    var result: [String: HuntEntry] = [:]
    func visit(_ path: String, _ relative: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let kind = info.st_mode & S_IFMT
        var entry = HuntEntry(
            kind: kind,
            mode: info.st_mode & 0o7777,
            uid: info.st_uid,
            gid: info.st_gid,
            flags: info.st_flags & huntComparableFlags,
            mtime: info.st_mtimespec.tv_sec,
            content: nil,
            linkTarget: nil,
            xattrs: huntXattrs(path, ignoring: ignoringXattrs),
            acl: huntACL(path),
        )
        if !includeRootFlags, relative.isEmpty { entry.flags = 0 }
        switch kind {
        case S_IFREG:
            entry.content = huntReadAll(path)
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = readlink(path, &buffer, buffer.count - 1)
            if length >= 0 { buffer[length] = 0; entry.linkTarget = String(cString: buffer) }
        case S_IFDIR:
            // Directory mtimes move as entries are created; compare only the rest.
            entry.mtime = 0
            if let handle = opendir(path) {
                var names: [String] = []
                while let record = readdir(handle) {
                    let name = withUnsafeBytes(of: record.pointee.d_name) { raw in
                        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                    }
                    if name != ".", name != ".." { names.append(name) }
                }
                closedir(handle)
                for name in names { visit(path + "/" + name, relative.isEmpty ? name : relative + "/" + name) }
            }
        default:
            break
        }
        result[relative] = entry
    }
    visit(root, "")
    return result
}

/// The differences between two snapshots, one line each.
func huntDiff(_ expected: [String: HuntEntry], _ actual: [String: HuntEntry]) -> [String] {
    var lines: [String] = []
    for key in Set(expected.keys).union(actual.keys).sorted() {
        switch (expected[key], actual[key]) {
        case let (e?, a?) where e != a: lines.append("changed \(key.debugDescription): \(e) -> \(a)")
        case (_?, nil): lines.append("missing \(key.debugDescription)")
        case (nil, _?): lines.append("extra \(key.debugDescription)")
        default: break
        }
    }
    return lines
}

// MARK: - Random trees

struct HuntTreeOptions {
    var immutable = false
    var fifo = false
    var hardLinks = true
    var sparse = false
    var resourceFork = true
    var acl = true
    var longNames = true
    var maxDepth = 6
}

/// A random tree at `root` (created). Returns how many nodes it made.
@discardableResult
func huntBuildTree(at root: String, seed: UInt64, nodes: Int, options: HuntTreeOptions = HuntTreeOptions()) -> Int {
    var random = HuntRandom(seed: seed)
    precondition(mkdir(root, 0o755) == 0 || errno == EEXIST)
    var directories = [root]
    var files: [String] = []
    var made = 0
    var immutables: [String] = []
    func name(_ index: Int) -> String {
        if options.longNames, Int.random(in: 0 ..< 12, using: &random) == 0 {
            let stem = "L\(index)-"
            return stem + String(repeating: "n", count: 255 - stem.utf8.count)
        }
        let pool = ["file", "Data", "é-nfc", "e\u{301}-nfd", "space name", ".hidden", "日本語", "emoji-🙂", "x"]
        return pool.randomElement(using: &random)! + "-\(index)"
    }
    for index in 0 ..< nodes {
        let parent = directories.randomElement(using: &random)!
        let depth = parent.dropFirst(root.count).split(separator: "/").count
        let path = parent + "/" + name(index)
        var choice = Int.random(in: 0 ..< 10, using: &random)
        if depth >= options.maxDepth, choice < 3 { choice = 3 }
        switch choice {
        case 0 ..< 3:
            guard mkdir(path, 0o755) == 0 else { continue }
            directories.append(path)
        case 3 ..< 7:
            let size = [0, 1, 17, 4096, 70000].randomElement(using: &random)!
            var bytes = [UInt8](repeating: 0, count: size)
            for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: random.next()) }
            let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, [0o644, 0o600, 0o755, 0o444].randomElement(using: &random)!)
            guard fd >= 0 else { continue }
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            files.append(path)
            let value = Array("v\(random.next())".utf8)
            _ = value.withUnsafeBytes { setxattr(path, "wiki.qaq.hunt.\(index % 3)", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            if options.resourceFork, Int.random(in: 0 ..< 6, using: &random) == 0 {
                var fork = [UInt8](repeating: 0, count: 100_000)
                for i in stride(from: 0, to: fork.count, by: 97) { fork[i] = UInt8(truncatingIfNeeded: i) }
                _ = fork.withUnsafeBytes { setxattr(path, XATTR_RESOURCEFORK_NAME, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            }
            if Int.random(in: 0 ..< 5, using: &random) == 0 { _ = lchflags(path, UInt32(UF_HIDDEN | UF_NODUMP)) }
            if options.acl, Int.random(in: 0 ..< 8, using: &random) == 0 { huntSetACL(path) }
            if options.immutable, Int.random(in: 0 ..< 8, using: &random) == 0 { immutables.append(path) }
        case 7:
            let targets = ["missing", "../", "/private/tmp", "self-\(index)", files.last.map { ($0 as NSString).lastPathComponent } ?? "x"]
            let target = targets.randomElement(using: &random)!
            if target == "self-\(index)" {
                _ = symlink(path, path) // a loop onto itself
            } else {
                _ = symlink(target, path)
            }
        case 8:
            if options.hardLinks, let existing = files.randomElement(using: &random) {
                _ = link(existing, path)
            } else if options.sparse {
                let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                guard fd >= 0 else { continue }
                _ = lseek(fd, 8 * 1024 * 1024, SEEK_SET)
                _ = "tail".withCString { write(fd, $0, 4) }
                close(fd)
            }
        default:
            if options.fifo { _ = mkfifo(path, 0o644) } else { _ = mkdir(path, 0o700) }
        }
        made += 1
    }
    for path in immutables { _ = lchflags(path, UInt32(UF_IMMUTABLE)) }
    return made
}

func huntSetACL(_ path: String) {
    var acl = acl_init(1)
    defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
    var entry: acl_entry_t?
    guard acl_create_entry(&acl, &entry) == 0, let access = entry,
          var identity = UUID(uuidString: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000")?.uuid
    else { return }
    _ = acl_set_tag_type(access, ACL_EXTENDED_ALLOW)
    _ = acl_set_qualifier(access, &identity)
    _ = acl_set_permset_mask_np(access, UInt64(ACL_READ_DATA.rawValue))
    _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, acl)
}

func huntRunJob(_ request: JobRequest, _ operations: FileOperations, report: @escaping (FileJob, JobProgress) -> Void = { _, _ in }) -> FilaFailure {
    let job = FileJob(request: request, operations: operations)
    return job.run { report(job, $0) }
}

/// Names in `directory` that look like an unpublished job temporary.
func huntLeftoverTemporaries(in directory: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter {
        $0.hasPrefix(".fila-copy-") || $0.hasPrefix(".fila-provider-")
    }
}

let huntTrashAttributes: Set<String> = [FilaTrash.originAttribute, FilaTrash.jobAttribute]
