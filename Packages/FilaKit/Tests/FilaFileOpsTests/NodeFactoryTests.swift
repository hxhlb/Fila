import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

@Suite("Creating nodes")
struct NodeFactoryTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    @Test(arguments: [NodeTemplate.emptyFile, .directory, .symbolicLink(target: "missing")])
    func `New files and directories use the default owner and exact 0777 mode`(_ template: NodeTemplate) throws {
        let path = scratch.path("new")
        try operations.create(template, at: path)
        let node = try #require(metadata(of: path))
        #expect(node.st_mode & 0o7777 == 0o777)
        #expect(node.st_uid == (geteuid() == 0 ? 501 : getuid()))
        #expect(node.st_gid == (geteuid() == 0 ? 501 : getgid()))
    }

    @Test
    func `Explicit private creation and hard links retain their permissions`() throws {
        let path = scratch.path("private")
        try operations.create(.directory, at: path, mode: 0o700)
        #expect(metadata(of: path).map { $0.st_mode & 0o7777 } == 0o700)
        let original = scratch.file("source", contents: "source", mode: 0o640)
        try operations.create(.hardLink(existing: original), at: scratch.path("link"))
        #expect(metadata(of: original).map { $0.st_mode & 0o7777 } == 0o640)
    }

    @Test
    func `Each template makes what it says`() throws {
        try operations.create(.directory, at: scratch.path("folder"))
        #expect(metadata(of: scratch.path("folder")).map { $0.st_mode & S_IFMT == S_IFDIR } == true)

        try operations.create(.emptyFile, at: scratch.path("empty.txt"))
        #expect(metadata(of: scratch.path("empty.txt"))?.st_size == 0)

        try operations.create(.symbolicLink(target: "empty.txt"), at: scratch.path("pointer"))
        #expect(metadata(of: scratch.path("pointer")).map { $0.st_mode & S_IFMT == S_IFLNK } == true)

        try operations.create(.hardLink(existing: scratch.path("empty.txt")), at: scratch.path("second-name"))
        #expect(metadata(of: scratch.path("second-name"))?.st_ino == metadata(of: scratch.path("empty.txt"))?.st_ino)
    }

    @Test
    func `Creating a file never truncates one that is already there`() {
        scratch.file("existing.txt", contents: "precious")
        let failure = #expect(throws: FilaFailure.self) {
            try operations.create(.emptyFile, at: scratch.path("existing.txt"))
        }
        #expect(failure?.systemError == EEXIST)
        #expect(metadata(of: scratch.path("existing.txt"))?.st_size == 8)
    }

    @Test
    func `Renaming onto an existing name replaces it, and says so to the guard`() throws {
        let source = scratch.file("new.txt", contents: "fresh")
        scratch.file("old.txt", contents: "stale")

        try operations.rename(source, to: scratch.path("old.txt"))
        #expect(!exists(source))
        #expect(metadata(of: scratch.path("old.txt"))?.st_size == 5)
    }

    @Test
    func `An exclusive rename refuses to replace, and leaves both files alone`() {
        let source = scratch.file("new.txt", contents: "fresh")
        scratch.file("old.txt", contents: "stale")

        // The check-then-act a caller picking a free name would otherwise do:
        // the name it checked can be taken before the rename runs, and POSIX
        // `rename(2)` would destroy what appeared there without a word.
        let failure = #expect(throws: FilaFailure.self) {
            try operations.rename(source, to: scratch.path("old.txt"), exclusive: true)
        }
        #expect(failure?.systemError == EEXIST)
        #expect(metadata(of: source)?.st_size == 5)
        #expect(metadata(of: scratch.path("old.txt"))?.st_size == 5)
    }

    @Test
    func `An exclusive rename into a free name is an ordinary move`() throws {
        let source = scratch.file("new.txt", contents: "fresh")

        try operations.rename(source, to: scratch.path("moved.txt"), exclusive: true)
        #expect(!exists(source))
        #expect(metadata(of: scratch.path("moved.txt"))?.st_size == 5)
    }

    /// POSIX `rename(2)` between two names of one file succeeds and changes
    /// nothing, so a Replace the user confirmed reported success and left
    /// both names in place.
    @Test
    func `Replacing a second name of the same file leaves only the destination`() throws {
        let source = scratch.file("h1.txt", contents: "shared")
        #expect(Darwin.link(source, scratch.path("h2.txt")) == 0)

        try operations.rename(source, to: scratch.path("h2.txt"))
        #expect(!exists(source))
        #expect(metadata(of: scratch.path("h2.txt"))?.st_nlink == 1)
        #expect(metadata(of: scratch.path("h2.txt"))?.st_size == 6)
    }

    /// The same entry spelled with other case is the kernel's to rename on a
    /// case-insensitive volume, and must not be mistaken for a second name.
    @Test
    func `A case-only rename of a hard-linked file keeps the file`() throws {
        let source = scratch.file("Case.txt", contents: "shared")
        #expect(Darwin.link(source, scratch.path("elsewhere.txt")) == 0)

        try operations.rename(source, to: scratch.path("case.txt"))
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.root)
        #expect(names.contains("case.txt") || names.contains("Case.txt"))
        #expect(metadata(of: scratch.path("case.txt"))?.st_nlink == 2)
    }

    /// APFS folds case pairs Foundation's comparison calls different — the
    /// Deseret letters — so the two spellings are one entry, and the file's
    /// only name must survive a confirmed Replace between them.
    @Test(.enabled(if: filaTemporaryVolumeFoldsDeseret, "the host's temporary volume is case-sensitive"))
    func `A rename between spellings the volume folds keeps the file's only name`() throws {
        let source = scratch.file("\u{10400}notes", contents: "only")

        try operations.rename(source, to: scratch.path("\u{10428}notes"))
        #expect(try String(contentsOfFile: scratch.path("\u{10428}notes"), encoding: .utf8) == "only")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root).count == 1)
    }

    /// The same, with a second name elsewhere: a link count above one does
    /// not make two spellings of one entry into two entries.
    @Test(.enabled(if: filaTemporaryVolumeFoldsDeseret, "the host's temporary volume is case-sensitive"))
    func `A rename between folded spellings of a hard-linked file keeps both names`() throws {
        let source = scratch.file("\u{10400}shared", contents: "shared")
        #expect(Darwin.link(source, scratch.path("elsewhere.txt")) == 0)

        try operations.rename(source, to: scratch.path("\u{10428}shared"))
        #expect(metadata(of: scratch.path("\u{10428}shared"))?.st_nlink == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root).count == 2)
    }
}

/// Whether the host's temporary volume folds the Deseret capital and small
/// letters into one entry, as a case-insensitive APFS volume does.
let filaTemporaryVolumeFoldsDeseret: Bool = {
    let folder = NSTemporaryDirectory() + "fila-fold-" + UUID().uuidString
    guard mkdir(folder, 0o700) == 0 else { return false }
    defer { rmdir(folder) }
    let descriptor = open(folder + "/\u{10400}", O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard descriptor >= 0 else { return false }
    close(descriptor)
    defer { unlink(folder + "/\u{10400}") }
    var status = stat()
    return lstat(folder + "/\u{10428}", &status) == 0
}()
