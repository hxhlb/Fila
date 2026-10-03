import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

/// Randomised trees pushed through copy, move, trash, Put Back and delete on
/// one volume, with byte and metadata comparison after each.
@Suite("Random trees", .serialized)
struct RandomTreeTests {
    private static let seeds: [UInt64] = [1, 2, 3, 5, 8, 13, 21, 34]

    @Test(.timeLimit(.minutes(1)), arguments: seeds)
    func `copy reproduces the tree byte for byte and touches nothing else`(seed: UInt64) {
        let scratch = HuntScratch("copy")
        let sentinel = scratch.file("sentinel", "outside")
        // No ACLs: a directory clone carries CLONE_ACL to its root only, and
        // the children's ACLs are a known loss — `a cloned file keeps its ACL`
        // covers what the flag does reach.
        huntBuildTree(at: scratch.path("src"), seed: seed, nodes: 60, options: HuntTreeOptions(immutable: true, fifo: true, sparse: true, acl: false))
        scratch.directory("dst")
        let before = huntSnapshot(scratch.path("src"))
        let outcome = huntRunJob(JobRequest(kind: .copy, sources: [scratch.path("src")], destination: scratch.path("dst")), FileOperations(bootstrapRoot: ""))
        #expect(outcome.code == .success, "seed \(seed): \(outcome)")
        let diffSource = huntDiff(before, huntSnapshot(scratch.path("src")))
        #expect(diffSource.isEmpty, "seed \(seed) source changed: \(diffSource.prefix(5))")
        let diffCopy = huntDiff(before, huntSnapshot(scratch.path("dst/src")))
        #expect(diffCopy.isEmpty, "seed \(seed) copy differs: \(diffCopy.prefix(5))")
        #expect(huntLeftoverTemporaries(in: scratch.path("dst")).isEmpty)
        #expect(huntReadAll(sentinel) == Array("outside".utf8))
    }

    @Test(.timeLimit(.minutes(1)), arguments: seeds)
    func `move keeps every node and its metadata`(seed: UInt64) {
        let scratch = HuntScratch("move")
        huntBuildTree(at: scratch.path("src"), seed: seed, nodes: 60, options: HuntTreeOptions(immutable: true, fifo: true, sparse: true))
        scratch.directory("dst")
        let before = huntSnapshot(scratch.path("src"))
        let outcome = huntRunJob(JobRequest(kind: .move, sources: [scratch.path("src")], destination: scratch.path("dst")), FileOperations(bootstrapRoot: ""))
        #expect(outcome.code == .success, "seed \(seed): \(outcome)")
        #expect(!exists(scratch.path("src")))
        let diff = huntDiff(before, huntSnapshot(scratch.path("dst/src")))
        #expect(diff.isEmpty, "seed \(seed): \(diff.prefix(5))")
    }

    @Test(.timeLimit(.minutes(1)), arguments: seeds)
    func `trash then Put Back restores the exact tree and clears the record`(seed: UInt64) {
        let scratch = HuntScratch("trash")
        let boot = scratch.directory("boot")
        let operations = FileOperations(bootstrapRoot: boot)
        scratch.directory("home")
        // Several items, two sharing a name, to exercise suffixes.
        huntBuildTree(at: scratch.path("home/a"), seed: seed, nodes: 30, options: HuntTreeOptions(immutable: true, fifo: true))
        scratch.directory("home/other")
        huntBuildTree(at: scratch.path("home/other/a"), seed: seed &+ 99, nodes: 20)
        let file = scratch.file("home/loose.txt", "loose")
        let roots = [scratch.path("home/a"), scratch.path("home/other/a"), file]
        let before = roots.map { huntSnapshot($0) }
        let identity = UUID()
        let trashed = huntRunJob(JobRequest(kind: .delete, sources: roots, useTrash: true, trashID: identity), operations)
        #expect(trashed.code == .success, "seed \(seed): \(trashed)")
        for root in roots { #expect(!exists(root)) }

        let trash = FilaTrash.directory(under: boot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? []
        #expect(names.count == 3, "\(names)")
        var restored: [String] = []
        for name in names {
            let item = trash + "/" + name
            #expect(extendedAttribute(FilaTrash.jobAttribute, at: item) == identity.uuidString, "\(name)")
            restored.append(item)
        }
        let back = huntRunJob(JobRequest(kind: .restore, sources: restored, trashID: identity), operations)
        #expect(back.code == .success, "seed \(seed): \(back)")
        for (root, snapshot) in zip(roots, before) {
            let diff = huntDiff(snapshot, huntSnapshot(root))
            #expect(diff.isEmpty, "seed \(seed) \(root): \(diff.prefix(5))")
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? ["?"]).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: seeds)
    func `permanent delete removes the tree and never follows a link out of it`(seed: UInt64) {
        let scratch = HuntScratch("delete")
        let outside = scratch.directory("outside")
        let kept = scratch.file("outside/kept", "kept")
        huntBuildTree(at: scratch.path("tree"), seed: seed, nodes: 60, options: HuntTreeOptions(fifo: true, sparse: true))
        // Links that point out of the tree, absolute and relative, to a directory.
        _ = symlink(outside, scratch.path("tree/abs-out"))
        _ = symlink("../outside", scratch.path("tree/rel-out"))
        let outcome = huntRunJob(JobRequest(kind: .delete, sources: [scratch.path("tree")]), FileOperations(bootstrapRoot: ""))
        #expect(outcome.code == .success, "seed \(seed): \(outcome)")
        #expect(!exists(scratch.path("tree")))
        #expect(huntReadAll(kept) == Array("kept".utf8))
    }

    @Test
    func `a second trashed item with a 255-byte name gets a usable trash name`() {
        let scratch = HuntScratch("longname")
        let boot = scratch.directory("boot")
        let operations = FileOperations(bootstrapRoot: boot)
        let name = String(repeating: "n", count: 255)
        scratch.directory("one")
        scratch.directory("two")
        let first = scratch.file("one/" + name, "first")
        let second = scratch.file("two/" + name, "second")
        #expect(huntRunJob(JobRequest(kind: .delete, sources: [first], useTrash: true), operations).code == .success)
        let outcome = huntRunJob(JobRequest(kind: .delete, sources: [second], useTrash: true), operations)
        // The trash already holds that name; the second deletion has to pick
        // another one rather than fail.
        #expect(outcome.code == .success, "second trash of a 255-byte name: \(outcome)")
        #expect(!exists(second))
    }

    @Test
    func `a shortened trash name stays whole characters and within one component`() {
        // 85 three-byte characters are exactly 255 bytes, so "-1" displaces one.
        let name = String(repeating: "雪", count: 85)
        #expect(FilaTrash.itemName(name, suffix: 0) == name)
        #expect(FilaTrash.itemName(name, suffix: 1) == String(repeating: "雪", count: 84) + "-1")
        #expect(FilaTrash.itemName("short", suffix: 12) == "short-12")
        for suffix in [1, 9, 10, 999] {
            #expect(FilaTrash.itemName(name, suffix: suffix).utf8.count <= 255)
        }
    }

    /// A plain clone drops the source's ACL; CLONE_ACL keeps it.
    @Test
    func `a cloned file keeps its ACL`() throws {
        let scratch = HuntScratch("acl")
        let source = scratch.file("guarded.txt", "acl")
        huntSetACL(source)
        let before = try #require(huntACL(source))
        scratch.directory("dst")
        #expect(huntRunJob(JobRequest(kind: .copy, sources: [source], destination: scratch.path("dst")), FileOperations(bootstrapRoot: "")).code == .success)
        #expect(huntACL(scratch.path("dst/guarded.txt")) == before)
    }

    @Test
    func `copy of a sparse file keeps its holes on the same volume`() throws {
        let scratch = HuntScratch("sparse")
        let source = scratch.path("sparse.img")
        let fd = open(source, O_CREAT | O_WRONLY, 0o644)
        try #require(fd >= 0)
        _ = lseek(fd, 64 * 1024 * 1024, SEEK_SET)
        _ = "tail".withCString { write(fd, $0, 4) }
        close(fd)
        scratch.directory("dst")
        #expect(huntRunJob(JobRequest(kind: .copy, sources: [source], destination: scratch.path("dst")), FileOperations(bootstrapRoot: "")).code == .success)
        let copied = try #require(metadata(of: scratch.path("dst/sparse.img")))
        #expect(copied.st_size == 64 * 1024 * 1024 + 4)
        #expect(Int64(copied.st_blocks) * 512 < 8 * 1024 * 1024, "allocated \(Int64(copied.st_blocks) * 512)")
    }
}

/// Paths whose components begin with a grapheme-extending scalar. The kernel
/// splits paths on the byte 0x2F; Swift `Character` operations do not, because
/// U+0301 (or ZWJ, or a variation selector) after "/" forms one grapheme with it.
@Suite("Path components are bytes, not graphemes")
struct PathComponentTests {
    private let leaders = ["\u{301}", "\u{200D}", "\u{FE0F}"]

    @Test
    func `name and directory split at the last separator byte`() {
        for leader in leaders {
            let path = "/private/tmp/dir/\(leader)file"
            #expect(FilaPath.name(of: path) == "\(leader)file", "name of \(path.unicodeScalars.map { String($0.value, radix: 16) })")
            #expect(FilaPath.directory(of: path) == "/private/tmp/dir", "directory of \(leader.unicodeScalars.first!.value)")
        }
    }

    @Test
    func `isAncestor sees a child whose name starts with a combining mark`() {
        for leader in leaders {
            #expect(FilaGuard.isAncestor("/a/tree", of: "/a/tree/\(leader)inner"), "leader U+\(String(leader.unicodeScalars.first!.value, radix: 16))")
        }
    }

    @Test
    func `canonical resolves the parent of a combining-mark leaf`() throws {
        let scratch = HuntScratch("grapheme-canon")
        scratch.directory("real")
        _ = symlink(scratch.path("real"), scratch.path("alias"))
        for leader in leaders {
            let canonical = try FilaPath.canonical(scratch.path("alias/\(leader)x"))
            #expect(canonical == scratch.path("real/\(leader)x"), "got \(canonical)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `copying a tree into its own combining-mark subfolder is refused`() {
        let scratch = HuntScratch("grapheme-self")
        scratch.directory("tree/\u{301}inner")
        scratch.file("tree/payload", "p")
        let outcome = huntRunJob(
            JobRequest(kind: .copy, sources: [scratch.path("tree")], destination: scratch.path("tree/\u{301}inner")),
            FileOperations(bootstrapRoot: ""),
        )
        #expect(outcome.reason == .insideSource, "outcome \(outcome)")
        #expect(!exists(scratch.path("tree/\u{301}inner/tree")), "the tree was copied into itself")
    }

    @Test
    func `a copied file whose name starts with a combining mark lands in the destination folder`() {
        let scratch = HuntScratch("grapheme-copy")
        scratch.directory("src")
        let source = scratch.file("src/\u{301}x", "payload")
        scratch.directory("dst/src") // a folder in the destination that shares the parent's name
        let outcome = huntRunJob(JobRequest(kind: .copy, sources: [source], destination: scratch.path("dst")), FileOperations(bootstrapRoot: ""))
        #expect(outcome.code == .success, "\(outcome)")
        #expect(exists(scratch.path("dst/\u{301}x")), "expected dst/<U+0301>x")
        #expect(!exists(scratch.path("dst/src/\u{301}x")), "the copy landed one folder too deep")
    }

    @Test
    func `trash and Put Back of a combining-mark name`() {
        let scratch = HuntScratch("grapheme-trash")
        let boot = scratch.directory("boot")
        let operations = FileOperations(bootstrapRoot: boot)
        scratch.directory("home/docs")
        let file = scratch.file("home/docs/\u{301}note", "keep")
        let trashed = huntRunJob(JobRequest(kind: .delete, sources: [file], useTrash: true), operations)
        #expect(trashed.code == .success, "trash: \(trashed)")
        let item = FilaTrash.directory(under: boot) + "/\u{301}note"
        #expect(exists(item))
        let back = huntRunJob(JobRequest(kind: .restore, sources: [item]), operations)
        #expect(back.code == .success, "put back: \(back)")
        #expect(huntReadAll(file) == Array("keep".utf8))
    }
}
