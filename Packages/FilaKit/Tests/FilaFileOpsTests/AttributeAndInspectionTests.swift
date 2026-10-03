import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

@Suite("Attributes")
struct AttributeWriterTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    @Test
    func `A recursive change reaches a nested file`() throws {
        scratch.directory("tree/one/two")
        let deep = scratch.file("tree/one/two/leaf.txt", mode: 0o644)
        let shallow = scratch.file("tree/sibling.txt", mode: 0o644)

        // 0o700 rather than 0o600: taking the execute bit off a directory stops
        // the walk that is under test, for the ordinary reason that nobody but
        // root may then read through it.
        try operations.setAttributes(AttributeChange(mode: 0o700, isRecursive: true), at: scratch.path("tree"))

        #expect(permissions(of: deep) == 0o700)
        #expect(permissions(of: shallow) == 0o700)
        #expect(permissions(of: scratch.path("tree/one")) == 0o700)
    }

    @Test
    func `A recursive change does not walk through a symlink`() throws {
        scratch.directory("tree")
        scratch.directory("outside")
        let outsider = scratch.file("outside/untouched.txt", mode: 0o644)
        scratch.link("tree/escape", to: scratch.path("outside"))

        try operations.setAttributes(AttributeChange(mode: 0o700, isRecursive: true), at: scratch.path("tree"))
        #expect(permissions(of: scratch.path("tree/escape")) == 0o700)
        #expect(permissions(of: outsider) == 0o644)
    }

    /// Anyone who can write a folder can hard-link a file they do not own into
    /// it. A recursive change run as root must not reach that file through the
    /// name nobody chose to include.
    @Test
    func `A recursive change leaves a hard-linked file beneath it alone`() throws {
        scratch.directory("tree")
        scratch.directory("outside")
        let shared = scratch.file("outside/shared.txt", mode: 0o644)
        #expect(Darwin.link(shared, scratch.path("tree/planted.txt")) == 0)
        let own = scratch.file("tree/own.txt", mode: 0o644)

        let outcome = try operations.setAttributes(AttributeChange(mode: 0o700, isRecursive: true), at: scratch.path("tree"))
        #expect(permissions(of: own) == 0o700)
        #expect(permissions(of: shared) == 0o644)
        // Left alone on purpose, and said so: a partial change is not reported
        // as a whole one.
        #expect(outcome.unchangedSharedFiles == 1)

        // Named directly, it is changed as asked.
        let direct = try operations.setAttributes(AttributeChange(mode: 0o600), at: scratch.path("tree/planted.txt"))
        #expect(permissions(of: shared) == 0o600)
        #expect(direct.unchangedSharedFiles == 0)
    }

    @Test
    func `Times, flags and one extended attribute, each on its own`() throws {
        let file = scratch.file("subject.txt")

        try operations.setAttributes(AttributeChange(modified: 1_234_567), at: file)
        #expect(metadata(of: file)?.st_mtimespec.tv_sec == 1_234_567)

        try operations.setAttributes(AttributeChange(systemFlags: UInt32(UF_HIDDEN)), at: file)
        #expect(hasFlag(UF_HIDDEN, at: file))

        try operations.setAttributes(
            AttributeChange(extendedAttribute: ("wiki.qaq.fila.test", Data("here".utf8))),
            at: file,
        )
        #expect(extendedAttribute("wiki.qaq.fila.test", at: file) == "here")

        try operations.setAttributes(
            AttributeChange(extendedAttribute: ("wiki.qaq.fila.test", nil)),
            at: file,
        )
        #expect(extendedAttribute("wiki.qaq.fila.test", at: file) == nil)
    }

    @Test
    func `Setting one timestamp leaves the other where it was`() throws {
        let file = scratch.file("subject.txt")
        var times = [timeval(tv_sec: 111_111, tv_usec: 0), timeval(tv_sec: 222_222, tv_usec: 0)]
        #expect(lutimes(file, &times) == 0)

        try operations.setAttributes(AttributeChange(modified: 999_999), at: file)
        let after = try #require(metadata(of: file))
        #expect(after.st_mtimespec.tv_sec == 999_999)
        #expect(after.st_atimespec.tv_sec == 111_111)
    }

    /// The editor sends the folder's own word with one bit toggled. Each
    /// descendant takes that bit and keeps its own others: a locked file stays
    /// locked, and nothing the folder carries is stamped onto the tree.
    @Test
    func `A recursive flag change sets and clears only the bits that changed`() throws {
        let tree = scratch.directory("tree")
        let locked = scratch.file("tree/locked.txt")
        let marked = scratch.file("tree/marked.txt")
        defer { _ = lchflags(locked, 0) }
        #expect(lchflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        #expect(lchflags(marked, UInt32(UF_NODUMP | UF_HIDDEN)) == 0)
        #expect(lchflags(tree, UInt32(UF_NODUMP)) == 0)

        // Turning Hidden on for a folder that carries nodump.
        try operations.setAttributes(AttributeChange(systemFlags: UInt32(UF_NODUMP | UF_HIDDEN), isRecursive: true), at: tree)
        #expect(metadata(of: tree)?.st_flags == UInt32(UF_NODUMP | UF_HIDDEN))
        #expect(metadata(of: locked)?.st_flags == UInt32(UF_IMMUTABLE | UF_HIDDEN))
        #expect(metadata(of: marked)?.st_flags == UInt32(UF_NODUMP | UF_HIDDEN))

        // And off again: only Hidden goes.
        try operations.setAttributes(AttributeChange(systemFlags: UInt32(UF_NODUMP), isRecursive: true), at: tree)
        #expect(metadata(of: tree)?.st_flags == UInt32(UF_NODUMP))
        #expect(metadata(of: locked)?.st_flags == UInt32(UF_IMMUTABLE))
        #expect(metadata(of: marked)?.st_flags == UInt32(UF_NODUMP))
    }

    /// Times arrive over XPC as doubles. Converting NaN, an infinity or a value
    /// past `time_t` traps, which in the daemon is every peer's jobs gone.
    @Test(arguments: [Double.nan, .infinity, -.infinity, 1e19, -1e19])
    func `A time that is not a time is refused, not trapped on`(seconds: Double) throws {
        let file = scratch.file("subject.txt")
        let before = try #require(metadata(of: file))
        let modified = #expect(throws: FilaFailure.self) {
            try operations.setAttributes(AttributeChange(modified: seconds), at: file)
        }
        #expect(modified?.code == .invalidRequest)
        let accessed = #expect(throws: FilaFailure.self) {
            try operations.setAttributes(AttributeChange(accessed: seconds), at: file)
        }
        #expect(accessed?.code == .invalidRequest)
        #expect(metadata(of: file)?.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
    }

    @Test
    func `A change on a symlink changes the link, not its target`() throws {
        let target = scratch.file("target.txt", mode: 0o644)
        let link = scratch.link("pointer", to: target)

        try operations.setAttributes(AttributeChange(systemFlags: UInt32(UF_HIDDEN)), at: link)
        #expect(hasFlag(UF_HIDDEN, at: link))
        #expect(!hasFlag(UF_HIDDEN, at: target))
    }
}

@Suite("Inspection")
struct FileInspectorTests {
    let scratch = Scratch()

    @Test
    func `Details come back under the path every decision was made about`() throws {
        let operations = FileOperations(bootstrapRoot: "")
        scratch.directory("folder")
        scratch.file("folder/subject.txt", contents: "12345")

        let details = try operations.details(of: scratch.path("folder/../folder/subject.txt"))
        #expect(details.path == scratch.path("folder/subject.txt"))
        #expect(details.node.name == "subject.txt")
        #expect(details.node.size == 5)
        #expect(details.isDestructionProtected == false)
    }

    @Test
    func `Details of a symlink describe the link`() throws {
        let operations = FileOperations(bootstrapRoot: "")
        let target = scratch.file("target.txt")
        let link = scratch.link("pointer", to: target)

        let details = try operations.details(of: link)
        #expect(details.node.kind == .symbolicLink)
        #expect(details.node.link?.target == target)
        #expect(details.node.link?.resolvedKind == .regular)
    }

    @Test
    func `The guard's verdict ships with the details`() throws {
        let operations = FileOperations(bootstrapRoot: scratch.root)
        scratch.directory("usr/lib")
        #expect(try operations.details(of: scratch.path("usr")).isDestructionProtected)
        #expect(try !operations.details(of: scratch.path("usr/lib")).isDestructionProtected)
    }

    @Test
    func `Extended attributes are listed by name and size, never by value`() throws {
        let operations = FileOperations(bootstrapRoot: "")
        let file = scratch.file("subject.txt")
        setExtendedAttribute("wiki.qaq.fila.one", to: "abc", at: file)
        setExtendedAttribute("wiki.qaq.fila.two", to: "abcdef", at: file)

        let details = try operations.details(of: file)
        let sizes = Dictionary(
            uniqueKeysWithValues: details.extendedAttributes.map { ($0.name, $0.byteCount) },
        )
        #expect(sizes["wiki.qaq.fila.one"] == 3)
        #expect(sizes["wiki.qaq.fila.two"] == 6)

        #expect(try operations.extendedAttribute("wiki.qaq.fila.two", at: file) == Data("abcdef".utf8))
    }

    @Test
    func `Volume identity is what says whether a move is a rename`() throws {
        let operations = FileOperations(bootstrapRoot: "")
        scratch.directory("here")
        let volume = try operations.volumeInfo(for: scratch.path("here"))
        #expect(volume.totalByteCount > 0)
        #expect(!volume.mountPoint.isEmpty)
        #expect(try volume.deviceIdentifier == operations.volumeInfo(for: scratch.root).deviceIdentifier)
    }

    @Test
    func `Mount table agrees with statfs for the root volume`() throws {
        let operations = FileOperations(bootstrapRoot: "")
        let volume = try operations.volumeInfo(for: "/")
        let mount = try #require(operations.mountPoints().first { $0.path == volume.mountPoint })
        #expect(mount.device == volume.deviceName)
        #expect(mount.filesystem == volume.filesystemType)
        #expect(mount.isReadOnly == volume.isReadOnly)
    }

    @Test
    func `A descriptor comes back opened, and the daemon read none of it`() throws {
        let operations = FileOperations(bootstrapRoot: "")
        let file = scratch.file("subject.txt", contents: "abcdef")
        let descriptor = try operations.open(file, flags: O_RDONLY, mode: 0)
        defer { close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: 16)
        let read = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, 16) }
        #expect(read == 6)
    }

    @Test
    func `A relative path is a client bug, not a path`() {
        let failure = #expect(throws: FilaFailure.self) {
            _ = try FilaPath.canonical("etc/passwd")
        }
        #expect(failure?.code == .invalidRequest)
    }
}
