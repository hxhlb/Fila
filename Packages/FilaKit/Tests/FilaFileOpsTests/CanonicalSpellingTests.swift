import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

/// The per-user temporary folder as a caller spells it — `/var/folders/…`,
/// through the `/var` symlink — or nil on a host that keeps it elsewhere.
private let symlinkedTemporaryParent: String? = {
    var parent = NSTemporaryDirectory()
    while parent.count > 1, parent.hasSuffix("/") {
        parent.removeLast()
    }
    guard parent.hasPrefix("/var/"), let resolved = try? FilaPath.resolve(parent), resolved != parent else { return nil }
    return parent
}()

/// Every operation that reopens a parent with `O_NOFOLLOW_ANY`, handed the
/// spelling a caller actually has rather than the canonical one.
///
/// `O_NOFOLLOW_ANY` refuses `/var` itself, which is a symlink into `/private`
/// on every Apple platform, so an operation that reopened the path it was
/// given rather than the one it canonicalised would fail every one of these
/// with ELOOP. The other suites run in scratch folders that are canonical
/// already and cannot see that.
@Suite("Paths spelled through /var", .enabled(if: symlinkedTemporaryParent != nil, "no /var-spelled temporary folder on this host"))
struct CanonicalSpellingTests {
    let scratch = Scratch(parent: symlinkedTemporaryParent ?? "/private/tmp")
    let operations = FileOperations(bootstrapRoot: "")

    /// `relative` inside the scratch folder, spelled through `/var`.
    private func spelled(_ relative: String) -> String {
        (symlinkedTemporaryParent ?? "") + "/" + FilaPath.name(of: scratch.root) + "/" + relative
    }

    @Test
    func `The single-node operations accept the /var spelling`() throws {
        scratch.file("saved.txt", contents: "stale")
        scratch.file(".saved.tmp", contents: "fresh")
        try operations.replaceItem(at: spelled("saved.txt"), withTemporary: spelled(".saved.tmp"))
        #expect(try String(contentsOfFile: scratch.path("saved.txt"), encoding: .utf8) == "fresh")

        scratch.file("old.txt")
        try operations.rename(spelled("old.txt"), to: spelled("new.txt"))
        #expect(exists(scratch.path("new.txt")))

        scratch.directory("tree/inner")
        scratch.file("tree/inner/leaf.txt", mode: 0o644)
        try operations.setAttributes(AttributeChange(mode: 0o700, isRecursive: true), at: spelled("tree"))
        #expect(permissions(of: scratch.path("tree/inner/leaf.txt")) == 0o700)

        try operations.removeNode(at: spelled("new.txt"), directory: false)
        #expect(!exists(scratch.path("new.txt")))
        scratch.directory("empty")
        try operations.removeEmptyDirectory(at: spelled("empty"))
        #expect(!exists(scratch.path("empty")))
    }

    @Test
    func `Move, delete and trash jobs accept the /var spelling`() {
        let run = { (operations: FileOperations, request: JobRequest) in
            FileJob(request: request, operations: operations).run { _ in }
        }
        scratch.directory("destination")
        scratch.file("moved.txt")
        #expect(run(operations, JobRequest(kind: .move, sources: [spelled("moved.txt")], destination: spelled("destination"))).code == .success)
        #expect(exists(scratch.path("destination/moved.txt")))

        scratch.file("copied.txt")
        #expect(run(operations, JobRequest(kind: .copy, sources: [spelled("copied.txt")], destination: spelled("destination"))).code == .success)
        #expect(exists(scratch.path("destination/copied.txt")))

        #expect(run(operations, JobRequest(kind: .delete, sources: [spelled("destination/copied.txt")])).code == .success)
        #expect(!exists(scratch.path("destination/copied.txt")))

        // A relocated bootstrap keeps its own trash, so nothing lands in the
        // host's volume-root trash.
        let bootstrap = Scratch()
        let relocated = FileOperations(bootstrapRoot: bootstrap.root)
        let identity = UUID()
        let trashed = run(relocated, JobRequest(kind: .delete, sources: [spelled("destination/moved.txt")], useTrash: true, trashID: identity))
        #expect(trashed.code == .success)
        #expect(!exists(scratch.path("destination/moved.txt")))
        #expect(exists(FilaTrash.directory(under: bootstrap.root) + "/moved.txt"))
    }
}
