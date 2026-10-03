import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

/// Atomic replace under failure: whatever goes wrong, the original keeps its
/// bytes and metadata. (The temporary belongs to the caller, which discards it.)
@Suite("Atomic replace under failure")
struct AtomicReplaceFailureTests {
    let operations = FileOperations(bootstrapRoot: "")

    private func original(_ scratch: HuntScratch, _ name: String = "config.plist") -> String {
        let path = scratch.file(name, "original bytes", mode: 0o640)
        setExtendedAttribute("wiki.qaq.hunt", to: "meta", at: path)
        var times = [timeval(tv_sec: 1_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000, tv_usec: 0)]
        _ = lutimes(path, &times)
        return path
    }

    @Test
    func `a read-only directory refuses the swap and keeps the original`() throws {
        try #require(geteuid() != 0)
        let scratch = HuntScratch("ro")
        scratch.directory("locked")
        let target = original(scratch, "locked/config.plist")
        let temporary = scratch.file("locked/.fila-tmp-1", "new")
        let before = huntSnapshot(target)
        #expect(chmod(scratch.path("locked"), 0o555) == 0)
        defer { chmod(scratch.path("locked"), 0o755) }
        #expect(throws: FilaFailure.self) { try operations.replaceItem(at: target, withTemporary: temporary) }
        #expect(huntDiff(before, huntSnapshot(target)).isEmpty)
    }

    @Test
    func `an immutable original refuses the swap and keeps its bytes`() {
        let scratch = HuntScratch("uchg")
        let target = original(scratch)
        #expect(lchflags(target, UInt32(UF_IMMUTABLE)) == 0)
        let before = huntSnapshot(target)
        let temporary = scratch.file(".fila-tmp-2", "new")
        let failure = #expect(throws: FilaFailure.self) { try operations.replaceItem(at: target, withTemporary: temporary) }
        #expect(failure?.systemError == EPERM)
        #expect(huntDiff(before, huntSnapshot(target)).isEmpty)
    }

    @Test
    func `a metadata copy that fails leaves the original alone`() {
        let scratch = HuntScratch("meta")
        let target = original(scratch)
        let before = huntSnapshot(target)
        let temporary = scratch.file(".fila-tmp-3", "new")
        // An immutable temporary refuses the xattr copy onto it.
        #expect(lchflags(temporary, UInt32(UF_IMMUTABLE)) == 0)
        #expect(throws: FilaFailure.self) { try operations.replaceItem(at: target, withTemporary: temporary) }
        #expect(huntDiff(before, huntSnapshot(target)).isEmpty)
    }

    @Test
    func `many replaces in a row leave exactly one file with the last content`() throws {
        let scratch = HuntScratch("burst")
        let target = original(scratch)
        for index in 0 ..< 300 {
            let temporary = scratch.file(".fila-tmp-burst-\(index)", "version \(index)")
            try operations.replaceItem(at: target, withTemporary: temporary)
        }
        #expect(huntReadAll(target) == Array("version 299".utf8))
        #expect(extendedAttribute("wiki.qaq.hunt", at: target) == "meta")
        #expect(permissions(of: target) == 0o640)
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.root)
        #expect(names == ["config.plist"], "\(names)")
    }

    /// Saving onto a link used to put a 0755 regular file in the link's place
    /// and leave the file it names with the old bytes. Callers save to the
    /// resolved target; one that does not is refused and nothing changes.
    @Test
    func `replacing a symlink name is refused and keeps the link and the file it names`() throws {
        let scratch = HuntScratch("link")
        let real = original(scratch, "real.conf")
        let link = scratch.path("alias.conf")
        #expect(symlink("real.conf", link) == 0)
        let before = huntSnapshot(real)
        let temporary = scratch.file(".fila-tmp-5", "edited")
        let failure = #expect(throws: FilaFailure.self) { try operations.replaceItem(at: link, withTemporary: temporary) }
        #expect(failure?.systemError == ELOOP)
        let after = try #require(metadata(of: link))
        #expect(after.st_mode & S_IFMT == S_IFLNK)
        #expect(huntDiff(before, huntSnapshot(real)).isEmpty)
    }
}
