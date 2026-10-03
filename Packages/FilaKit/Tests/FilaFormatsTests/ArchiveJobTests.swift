import FilaFileOps
@testable import FilaFormats
import FilaProtocol
import Foundation
import Testing

/// The job as the helper and the in-process backend run it: real files, real
/// descriptors, the same `FileOperations` the daemon uses.
@Suite("Archive jobs", .serialized)
struct ArchiveJobTests {
    private let operations = FileOperations(bootstrapRoot: "")

    private func run(_ request: JobRequest) -> (outcome: FilaFailure, progress: [JobProgress], notes: [String], skipped: Int64) {
        var progress: [JobProgress] = []
        var notes: [String] = []
        let job = ArchiveJob(request: request, operations: operations)
        let outcome = job.run { progress.append($0) } note: { notes.append($0) }
        return (outcome, progress, notes, job.skippedItems)
    }

    @Test
    func `Selected extraction finishes without scanning unrelated entries past the listing limit`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("many.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                try writer.addData("selected.txt", Data("selected".utf8))
                for index in 1 ... ArchiveReader.maximumEntryCount {
                    try writer.addData("other-\(index)", Data())
                }
                try writer.finish()
            }
            let destination = scratch.appendingPathComponent("out")
            let result = run(JobRequest(
                kind: .extract, sources: [archive.path], destination: destination.path,
                archive: ArchiveOptions(members: [ArchiveSelection(index: 0, declaredPath: "selected.txt")]),
            ))
            #expect(result.outcome.code == .success)
            #expect(try String(contentsOf: destination.appendingPathComponent("selected.txt"), encoding: .utf8) == "selected")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["selected.txt"])
        }
    }

    private func makeTree(in scratch: URL) throws -> URL {
        let tree = scratch.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try samplePayload(byteCount: 200_000).write(to: tree.appendingPathComponent("nested/payload.bin"))
        try Data("hello".utf8).write(to: tree.appendingPathComponent("top.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.appendingPathComponent("top.txt").path)
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "top.txt")
        return tree
    }

    @Test
    func `A tree compresses with totals and extracts back with its modes and its link`() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("tree.zip")
            let compressed = run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: ArchiveOptions()))
            #expect(compressed.outcome.code == .success)
            #expect(FileManager.default.fileExists(atPath: archive.path))
            #expect(compressed.progress.last?.itemsTotal == 5)
            #expect(compressed.progress.last?.bytesTotal == 200_005)
            #expect(compressed.progress.last?.fraction == 1)
            #expect(compressed.notes.isEmpty)

            let out = scratch.appendingPathComponent("out")
            let extracted = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, overwrite: true, archive: ArchiveOptions()))
            #expect(extracted.outcome.code == .success)
            #expect(try Data(contentsOf: out.appendingPathComponent("tree/nested/payload.bin")) == samplePayload(byteCount: 200_000))
            #expect(try String(contentsOf: out.appendingPathComponent("tree/top.txt"), encoding: .utf8) == "hello")
            let mode = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("tree/top.txt").path)[.posixPermissions] as? Int
            #expect(mode == 0o755)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("tree/link").path) == "top.txt")
            // A leftover temporary is a half-written member nobody asked for.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("tree").path).filter { $0.hasPrefix(".fila-") }
            #expect(leftovers.isEmpty)
        }
    }

    @Test
    func `Read-only folders receive all their children before archive modes are applied`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("folders.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addDirectory("folder", mode: 0o555)
                try writer.addDirectory("folder/nested", mode: 0o555)
                try writer.addData("folder/nested/song.txt", Data("song".utf8), mode: 0o444)
                try writer.finish()
            }
            let out = scratch.appendingPathComponent("out")
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.appendingPathComponent("folder").path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.appendingPathComponent("folder/nested").path)
            }
            let extracted = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, archive: ArchiveOptions()))
            #expect(extracted.outcome.code == .success)
            #expect(try Data(contentsOf: out.appendingPathComponent("folder/nested/song.txt")) == Data("song".utf8))
            #expect(try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("folder/nested").path)[.posixPermissions] as? Int == 0o555)
            #expect(try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("folder/nested/song.txt").path)[.posixPermissions] as? Int == 0o444)
        }
    }

    @Test
    func `A password locks a zip, the wrong one is its own outcome, and the right one opens it`() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("locked.zip")
            let options = ArchiveOptions(format: .zip, encryption: .aes256, password: "secret")
            #expect(run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: options)).outcome.code == .success)

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.first { $0.declaredPath == "tree/top.txt" }?.isEncrypted == true)

            let out = scratch.appendingPathComponent("out")
            for wrong in [nil, "wrong"] {
                let attempt = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, overwrite: true, archive: ArchiveOptions(password: wrong)))
                #expect(attempt.outcome.code == .wrongPassword)
                #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("tree/top.txt").path))
            }
            let right = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, overwrite: true, archive: ArchiveOptions(password: "secret")))
            #expect(right.outcome.code == .success)
            #expect(try String(contentsOf: out.appendingPathComponent("tree/top.txt"), encoding: .utf8) == "hello")
        }
    }

    @Test
    func `A tar refuses a password rather than writing an archive that is not locked`() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("tree.tar")
            let outcome = run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: ArchiveOptions(format: .tar, password: "secret"))).outcome
            #expect(outcome.code != .success)
            #expect(!FileManager.default.fileExists(atPath: archive.path))
        }
    }

    @Test
    func `An escaping name is skipped and said, and the selection is matched by position`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("hostile.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("xx/xx/etc/passwd", Data("owned".utf8))
                try writer.addData("safe.txt", Data("fine".utf8))
                try writer.addData("unwanted.txt", Data("no".utf8))
                try writer.finish()
            }
            var bytes = try Data(contentsOf: archive)
            bytes.replaceEvery("xx/xx/etc/passwd", with: "../../etc/passwd")
            try bytes.write(to: archive)

            let out = scratch.appendingPathComponent("out")
            let members = [ArchiveSelection(index: 0, declaredPath: "../../etc/passwd"), ArchiveSelection(index: 1, declaredPath: "safe.txt")]
            let result = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, overwrite: true, archive: ArchiveOptions(members: members)))
            #expect(result.outcome.code == .success)
            #expect(result.notes.count == 1)
            #expect(result.skipped == 1)
            #expect(result.notes.first?.contains("outside the destination") == true)
            #expect(try String(contentsOf: out.appendingPathComponent("safe.txt"), encoding: .utf8) == "fine")
            #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("unwanted.txt").path))
            #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("etc/passwd").path))

            // The same position naming a different member is the archive
            // having changed: skipped, never handed over.
            let stale = run(JobRequest(kind: .extract, sources: [archive.path], destination: scratch.appendingPathComponent("stale").path, overwrite: true, archive: ArchiveOptions(members: [ArchiveSelection(index: 2, declaredPath: "safe.txt")])))
            #expect(stale.outcome.code == .success)
            #expect(stale.notes.first?.contains("changed") == true)
            #expect(stale.skipped == 1)
            #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("stale/unwanted.txt").path))

            // A position the archive no longer reaches: it shrank after the
            // listing, and the member it named is counted, not forgotten.
            let gone = run(JobRequest(kind: .extract, sources: [archive.path], destination: scratch.appendingPathComponent("gone").path, overwrite: true, archive: ArchiveOptions(members: [ArchiveSelection(index: 1, declaredPath: "safe.txt"), ArchiveSelection(index: 9, declaredPath: "vanished.txt")])))
            #expect(gone.outcome.code == .success)
            #expect(gone.skipped == 1)
            #expect(gone.notes == ["skipped “vanished.txt”: the archive changed after it was listed"])
            #expect(try String(contentsOf: scratch.appendingPathComponent("gone/safe.txt"), encoding: .utf8) == "fine")
        }
    }

    @Test
    func `A clean extraction skips nothing`() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("tree.zip")
            #expect(run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: ArchiveOptions())).outcome.code == .success)
            let extracted = run(JobRequest(kind: .extract, sources: [archive.path], destination: scratch.appendingPathComponent("out").path, archive: ArchiveOptions()))
            #expect(extracted.outcome.code == .success)
            #expect(extracted.skipped == 0)
            #expect(extracted.notes.isEmpty)
        }
    }

    @Test
    func `A cancelled compress leaves no archive and no temporary behind`() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("tree.zip")
            let job = ArchiveJob(request: JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: ArchiveOptions()), operations: operations)
            var cancelledOnce = false
            let outcome = job.run { _ in
                if !cancelledOnce {
                    cancelledOnce = true; job.cancel()
                }
            }
            #expect(outcome.code == .cancelled)
            let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0 != "tree" }
            #expect(left.isEmpty)
        }
    }

    /// A tar whose members are given by hand, so a name can be anything the
    /// format allows — including a GNU long name far past `PATH_MAX`.
    private func handmadeTar(_ members: [(name: String, contents: Data)]) -> Data {
        var tar = Data()
        for member in members {
            if member.name.utf8.count > 100 {
                var name = Data(member.name.utf8)
                name.append(0)
                tar += huntUstarHeader(name: "././@LongLink", type: "L", size: name.count)
                tar += huntUstarPayload(name)
            }
            tar += huntUstarHeader(name: String(member.name.prefix(100)), type: "0", size: member.contents.count)
            tar += huntUstarPayload(member.contents)
        }
        return tar + Data(count: 1024)
    }

    /// Every progress line and note goes to a daemon launchd kills at 6 MB,
    /// and an archive chooses its own names.
    @Test
    func `A name too long to report is reported cut short and without control characters`() throws {
        try withScratch { scratch in
            let control = "ctl\u{1}name.txt"
            let long = String(repeating: "\u{1}", count: 200_000)
            let archive = scratch.appendingPathComponent("names.tar")
            try handmadeTar([(control, Data("one".utf8)), (long, Data("two".utf8))]).write(to: archive)
            let out = scratch.appendingPathComponent("out")
            let result = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, archive: ArchiveOptions()))

            // Placement still uses the archive's own name.
            #expect(try String(contentsOf: out.appendingPathComponent(control), encoding: .utf8) == "one")
            #expect(result.outcome.systemError == ENAMETOOLONG, "\(result.outcome.code)")
            let reported = result.progress.map(\.currentPath) + result.notes + [result.outcome.path ?? ""]
            #expect(reported.contains { $0.contains("ctl\u{FFFD}name.txt") })
            for text in reported {
                #expect(text.utf8.count <= 2 * ArchivePath.maximumDisplayByteCount, "\(text.utf8.count) bytes")
                #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .control })
            }
        }
    }

    /// Compress records no owner, so every member reads back as root's: a
    /// setuid bit kept beside that is a setuid-root program for any extractor
    /// that restores ownership as root.
    @Test(arguments: [ArchiveFormat.tarGzip, .zip])
    func `Compress leaves out setuid and setgid bits and keeps the sticky bit`(format: ArchiveFormat) throws {
        try withScratch { scratch in
            let shared = scratch.appendingPathComponent("shared")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            let tool = shared.appendingPathComponent("tool")
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            #expect(chmod(tool.path, 0o4755) == 0)
            #expect(chmod(shared.path, 0o1775) == 0)
            var metadata = stat()
            #expect(lstat(tool.path, &metadata) == 0 && metadata.st_mode & 0o4000 != 0, "the fixture carries the bit")

            let archive = scratch.appendingPathComponent("shared.\(format.filenameExtension)")
            let result = run(JobRequest(
                kind: .compress, sources: [shared.path], destination: archive.path,
                archive: ArchiveOptions(format: format),
            ))
            #expect(result.outcome.code == .success, "\(result.outcome)")
            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.map { $0.mode & 0o7777 } == [0o1775, 0o755])
        }
    }

    /// "/" plus a combining mark is one `Character`, so a name split on
    /// graphemes hides a `..` that the kernel walks.
    @Test(arguments: [false, true])
    func `A climb hidden behind a combining mark is skipped, not written above the destination`(organize: Bool) throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("grapheme.tar")
            try handmadeTar([
                ("../\u{301}x", Data("x".utf8)),
                ("a/../\u{301}../y", Data("y".utf8)),
                ("ok.txt", Data("ok".utf8)),
            ]).write(to: archive)
            let out = scratch.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let result = run(JobRequest(
                kind: .extract, sources: [archive.path], destination: out.path,
                archive: ArchiveOptions(organizeExtraction: organize),
            ))
            #expect(result.outcome.code == .success, "\(result.outcome)")
            #expect(result.notes.count == 2, "\(result.notes)")
            #expect(result.notes.allSatisfy { $0.contains("outside the destination") })
            #expect(try String(contentsOf: out.appendingPathComponent("ok.txt"), encoding: .utf8) == "ok")
            let above = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
            #expect(above == ["grapheme.tar", "out"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["ok.txt"])
        }
    }

    /// The race a less privileged process can run against a root extractor:
    /// a folder the job has already placed members in is replaced by a link
    /// out of the destination before the next member arrives.
    @Test
    func `A folder replaced by a link between members is not written through`() throws {
        try withScratch { scratch in
            let outside = scratch.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let archive = scratch.appendingPathComponent("race.tar")
            try handmadeTar([
                ("docs/a.txt", Data("a".utf8)),
                ("../escape.txt", Data("x".utf8)),
                ("docs/b.txt", Data("b".utf8)),
                ("docs/sub/c.txt", Data("c".utf8)),
            ]).write(to: archive)
            let out = scratch.appendingPathComponent("out")
            let docs = out.appendingPathComponent("docs")
            var swapped = false
            let job = ArchiveJob(
                request: JobRequest(kind: .extract, sources: [archive.path], destination: out.path, archive: ArchiveOptions()),
                operations: operations,
            )
            // The skipped climb's note arrives between `docs/a.txt` and
            // `docs/b.txt`, synchronously, which is the window.
            let outcome = job.run { _ in } note: { _ in
                guard !swapped else { return }
                swapped = true
                _ = rename(docs.path, out.appendingPathComponent("moved").path)
                _ = symlink(outside.path, docs.path)
            }
            #expect(swapped)
            #expect(outcome.code == .success, "\(outcome)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("moved/a.txt").path))
        }
    }

    /// A backend confined to one folder extracts nowhere else, organised or
    /// not: the workspace is made where the fence is enforced.
    @Test(arguments: [false, true])
    func `A confined backend refuses to extract outside its writable root`(organize: Bool) throws {
        try withScratch { scratch in
            let root = scratch.appendingPathComponent("root")
            let outside = scratch.appendingPathComponent("outside")
            for folder in [root, outside] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let archive = root.appendingPathComponent("fenced.tar")
            try handmadeTar([("a.txt", Data("a".utf8))]).write(to: archive)
            let confined = FileOperations(bootstrapRoot: "", writableRoot: root.path)
            let outcome = ArchiveJob(
                request: JobRequest(kind: .extract, sources: [archive.path], destination: outside.path,
                                    archive: ArchiveOptions(organizeExtraction: organize)),
                operations: confined,
            ).run { _ in }
            #expect(outcome.systemError == EROFS, "\(outcome)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    /// New members belong to mobile, as every new file does, and keep the
    /// archive's modes. Only observable as root.
    @Test(.enabled(if: geteuid() == 0))
    func `Extracted members are given to the new-item owner`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("owned.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addDirectory("folder", mode: 0o750)
                try writer.addData("folder/file.txt", Data("x".utf8), mode: 0o640)
                try writer.addSymbolicLink("folder/link", target: "file.txt")
                try writer.finish()
            }
            #expect(run(JobRequest(kind: .extract, sources: [archive.path], destination: scratch.path, archive: ArchiveOptions(organizeExtraction: true))).outcome.code == .success)
            for (path, mode) in [("folder", 0o750), ("folder/file.txt", 0o640), ("folder/link", nil)] {
                var metadata = stat()
                #expect(lstat(scratch.appendingPathComponent(path).path, &metadata) == 0)
                #expect(metadata.st_uid == 501 && metadata.st_gid == 501, "\(path)")
                if let mode {
                    #expect(Int(metadata.st_mode & 0o7777) == mode, "\(path)")
                }
            }
        }
    }
}
