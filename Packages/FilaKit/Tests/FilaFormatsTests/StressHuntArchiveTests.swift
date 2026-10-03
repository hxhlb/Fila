import FilaFileOps
@testable import FilaFormats
import FilaProtocol
import Foundation
import Testing

/// Every node under `root`, relative to it, found with `lstat` and never by
/// following a link: a containment check that walked through a planted link
/// would report the very escape it exists to catch as "inside".
func huntTree(_ root: URL) -> [String: FileAttributeType] {
    var result: [String: FileAttributeType] = [:]
    func walk(_ relative: String) {
        let path = relative.isEmpty ? root.path : root.path + "/" + relative
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in names {
            let child = relative.isEmpty ? name : relative + "/" + name
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.path + "/" + child)
            let type = attributes?[.type] as? FileAttributeType ?? .typeUnknown
            result[child] = type
            if type == .typeDirectory {
                walk(child)
            }
        }
    }
    walk("")
    return result
}

/// Gives the owner full access to every directory under `url`, so a tree
/// extracted with an archive's own read-only or unsearchable modes can be
/// removed. Links are never followed.
func huntMakeRemovable(_ url: URL) {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return }
    _ = chmod(url.path, (metadata.st_mode & 0o7777) | S_IRWXU)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
        huntMakeRemovable(url.appendingPathComponent(name))
    }
}

/// Deterministic, so a failing seed can be replayed.
struct HuntRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// A minimal ustar member header, for entry types `ArchiveWriter` has no way
/// to write (hard links, fifos, device nodes). Built the same way the `.deb`
/// fixture in `ArchiveTests` is: by hand, so the reader meets bytes its own
/// writer did not produce.
func huntUstarHeader(name: String, type: Character, size: Int = 0, mode: Int = 0o644, link: String = "") -> Data {
    var header = Data(count: 512)
    func put(_ text: String, at offset: Int, width: Int) {
        let bytes = Array(text.utf8.prefix(width))
        header.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }
    func octal(_ value: Int, at offset: Int, width: Int) {
        let digits = String(value, radix: 8)
        put(String(repeating: "0", count: max(0, width - 1 - digits.count)) + digits, at: offset, width: width - 1)
    }
    put(name, at: 0, width: 100)
    octal(mode, at: 100, width: 8)
    octal(501, at: 108, width: 8)
    octal(20, at: 116, width: 8)
    octal(size, at: 124, width: 12)
    octal(1_700_000_000, at: 136, width: 12)
    put("        ", at: 148, width: 8)
    header[156] = type.asciiValue!
    put(link, at: 157, width: 100)
    put("ustar\u{0}00", at: 257, width: 8)
    let sum = header.reduce(0) { $0 + Int($1) }
    let digits = String(sum, radix: 8)
    put(String(repeating: "0", count: max(0, 6 - digits.count)) + digits + "\u{0} ", at: 148, width: 8)
    return header
}

func huntUstarPayload(_ bytes: Data) -> Data {
    var padded = bytes
    let remainder = bytes.count % 512
    if remainder != 0 {
        padded.append(Data(count: 512 - remainder))
    }
    return padded
}

@Suite("Stress hunt: archive extraction", .serialized)
struct StressHuntArchiveTests {
    private let operations = FileOperations(bootstrapRoot: "")

    private func run(
        _ request: JobRequest,
        onProgress: ((ArchiveJob, JobProgress) -> Void)? = nil,
    ) -> (outcome: FilaFailure, notes: [String]) {
        var notes: [String] = []
        let job = ArchiveJob(request: request, operations: operations)
        let outcome = job.run { progress in onProgress?(job, progress) } note: { notes.append($0) }
        return (outcome, notes)
    }

    private func extract(
        _ archive: URL,
        into destination: URL,
        overwrite: Bool = false,
        organize: Bool? = nil,
    ) -> (outcome: FilaFailure, notes: [String]) {
        run(JobRequest(
            kind: .extract,
            sources: [archive.path],
            destination: destination.path,
            overwrite: overwrite,
            archive: ArchiveOptions(organizeExtraction: organize),
        ))
    }

    /// New nodes under `root` compared with `before`, minus those under any
    /// of `allowed`.
    private func strays(in root: URL, before: [String: FileAttributeType], allowed: [String]) -> [String] {
        huntTree(root).keys.filter { path in
            before[path] == nil && !allowed.contains { path == $0 || path.hasPrefix($0 + "/") }
        }.sorted()
    }

    // MARK: - Names

    /// Same-length placeholders patched into a zip, the way the existing
    /// escape test does it: names live in the local header and the central
    /// directory, and neither is covered by a checksum.
    @Test(arguments: [
        ("xx/escape.txt", "../escape.txt"),
        ("zabs/escape.txt", "/abs/escape.txt"),
        ("a/xx/xx/escape.txt", "a/../../escape.txt"),
        ("a/b/xx/xx/xx/escape.txt", "a/b/../../../escape.txt"),
        // The writer tidies `./` out of the names it is given, so these
        // placeholders carry no dot component of their own.
        ("z/xx/escape.txt", "./../escape.txt"),
        ("a/z/xx/xx/escape.txt", "a/./../../escape.txt"),
    ])
    func `A climbing or absolute name is skipped and nothing lands outside the destination`(
        placeholder: String,
        hostile: String,
    ) throws {
        for organize in [false, true] {
            try withScratch { scratch in
                let deep = scratch.appendingPathComponent("deep")
                try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
                let archive = scratch.appendingPathComponent("names.zip")
                try withDescriptor(writing: archive) { descriptor in
                    let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                    try writer.addData(placeholder, Data("owned".utf8))
                    try writer.addData("safe.txt", Data("fine".utf8))
                    try writer.finish()
                }
                var bytes = try Data(contentsOf: archive)
                bytes.replaceEvery(placeholder, with: hostile)
                try bytes.write(to: archive)
                let listed = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
                try #require(listed.map(\.declaredPath) == [hostile, "safe.txt"])

                let before = huntTree(scratch)
                let destination = organize ? deep : deep.appendingPathComponent("out")
                let result = extract(archive, into: destination, organize: organize)
                #expect(result.outcome.code == .success, "\(hostile) organize=\(organize): \(result.outcome)")
                #expect(result.notes.count == 1, "\(hostile): \(result.notes)")
                #expect(result.notes.first?.contains("outside the destination") == true, "\(result.notes)")
                let safe = organize ? deep.appendingPathComponent("safe.txt") : destination.appendingPathComponent("safe.txt")
                #expect(try String(contentsOf: safe, encoding: .utf8) == "fine")
                let allowed = organize ? ["deep/safe.txt"] : ["deep/out"]
                #expect(strays(in: scratch, before: before, allowed: allowed).isEmpty, "\(hostile): \(huntTree(scratch))")
                #expect(!FileManager.default.fileExists(atPath: "/abs/escape.txt"))
                let names = huntTree(scratch).keys
                #expect(!names.contains { $0.hasSuffix("escape.txt") }, "\(hostile): \(names.sorted())")
            }
        }
    }

    /// libarchive may read a backslash as a separator (it does for zips from
    /// Windows). Either way the member is one odd file inside the destination
    /// or a refused climb, and nothing lands outside.
    @Test
    func `A backslash name stays inside the destination or is refused`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("backslash.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("xx_xx_escape.txt", Data("odd".utf8))
                try writer.finish()
            }
            var bytes = try Data(contentsOf: archive)
            bytes.replaceEvery("xx_xx_escape.txt", with: "..\\..\\escape.txt")
            try bytes.write(to: archive)

            let before = huntTree(scratch)
            let out = scratch.appendingPathComponent("out")
            let result = extract(archive, into: out)
            #expect(result.outcome.code == .success)
            #expect(strays(in: scratch, before: before, allowed: ["out"]).isEmpty)
            let landed = huntTree(out).keys.sorted()
            if landed.isEmpty {
                #expect(result.notes.first?.contains("outside the destination") == true, "\(result.notes)")
            } else {
                #expect(landed == ["..\\..\\escape.txt"])
            }
        }
    }

    // MARK: - Links

    @Test
    func `Entries routed through a link the same archive planted never write outside`() throws {
        for organize in [false, true] {
            try withScratch { scratch in
                let outside = scratch.appendingPathComponent("outside")
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let outsidePath = try FilaPath.resolve(outside.path)
                let archive = scratch.appendingPathComponent("links.zip")
                try withDescriptor(writing: archive) { descriptor in
                    let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                    try writer.addSymbolicLink("pwn", target: outsidePath)
                    try writer.addSymbolicLink("pwn/inner", target: "x")
                    try writer.addSymbolicLink("pwn/deeper/inner", target: "x")
                    // A case variant and a normalisation variant of the same
                    // name, which a case- and normalisation-insensitive volume
                    // resolves to the link planted just before.
                    try writer.addSymbolicLink("CASE", target: outsidePath)
                    try writer.addSymbolicLink("case/inner", target: "x")
                    try writer.addSymbolicLink("\u{E9}t\u{E9}", target: outsidePath)
                    try writer.addSymbolicLink("e\u{301}te\u{301}/inner", target: "x")
                    // A relative link that climbs, then a link nested under it.
                    try writer.addSymbolicLink("up", target: "../outside")
                    try writer.addSymbolicLink("UP/inner", target: "x")
                    try writer.addData("safe.txt", Data("fine".utf8))
                    try writer.addData("second.txt", Data("fine".utf8))
                    try writer.finish()
                }
                let destination = organize ? scratch : scratch.appendingPathComponent("out")
                let result = extract(archive, into: destination, organize: organize)
                #expect(result.outcome.code == .success, "organize=\(organize): \(result.outcome) \(result.notes)")
                #expect(huntTree(outside).isEmpty, "organize=\(organize): \(huntTree(outside)) notes \(result.notes)")
            }
        }
    }

    /// The destination already holds a link the user made, pointing out of
    /// it. An archive entry nested under that name must not be written through it.
    @Test
    func `A pre-existing link in the destination is not written through`() throws {
        try withScratch { scratch in
            let outside = scratch.appendingPathComponent("outside")
            let out = scratch.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: out.appendingPathComponent("docs").path, withDestinationPath: outside.path)
            let archive = scratch.appendingPathComponent("into-link.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                try writer.addDirectory("docs")
                try writer.addData("docs/readme.txt", Data("hello".utf8))
                try writer.addDirectory("DOCS/sub")
                try writer.addSymbolicLink("docs/link", target: "x")
                try writer.finish()
            }
            let result = extract(archive, into: out)
            #expect(result.outcome.code == .success, "\(result.outcome)")
            #expect(huntTree(outside).isEmpty, "\(huntTree(outside)) notes \(result.notes)")
        }
    }

    // MARK: - Modes and node types

    @Test(arguments: [ArchiveFormat.tar, .zip])
    func `Setuid, setgid and sticky bits are dropped on the way out`(format: ArchiveFormat) throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("modes." + format.filenameExtension)
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: format)
                try writer.addDirectory("sticky", mode: 0o1777)
                try writer.addData("sticky/setuid", Data("x".utf8), mode: 0o4755)
                try writer.addData("setgid", Data("x".utf8), mode: 0o2755)
                try writer.addData("all", Data("x".utf8), mode: 0o7777)
                try writer.finish()
            }
            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            // The fixture really carries the bits, or this test proves nothing.
            #expect(entries.first { $0.relativePath == "sticky/setuid" }.map { $0.mode & 0o7000 } == 0o4000)

            let out = scratch.appendingPathComponent("out")
            let result = extract(archive, into: out)
            #expect(result.outcome.code == .success)
            for (path, expected) in [("sticky", 0o777), ("sticky/setuid", 0o755), ("setgid", 0o755), ("all", 0o777)] {
                var metadata = stat()
                #expect(lstat(out.appendingPathComponent(path).path, &metadata) == 0, "\(path)")
                #expect(Int(metadata.st_mode & 0o7777) == expected, "\(path): \(String(metadata.st_mode & 0o7777, radix: 8))")
            }
        }
    }

    @Test
    func `Hard links, fifos and device nodes are refused and the file a hard link names is untouched`() throws {
        try withScratch { scratch in
            let target = scratch.appendingPathComponent("target.txt")
            try Data("original".utf8).write(to: target)
            var tar = Data()
            tar += huntUstarHeader(name: "file.txt", type: "0", size: 5)
            tar += huntUstarPayload(Data("hello".utf8))
            tar += huntUstarHeader(name: "hard-out", type: "1", link: "../target.txt")
            tar += huntUstarHeader(name: "hard-in", type: "1", link: "file.txt")
            tar += huntUstarHeader(name: "fifo", type: "6")
            tar += huntUstarHeader(name: "chr", type: "3")
            tar += huntUstarHeader(name: "blk", type: "4")
            tar += huntUstarHeader(name: "suid-file", type: "0", size: 2, mode: 0o6755)
            tar += huntUstarPayload(Data("hi".utf8))
            tar += Data(count: 1024)
            let archive = scratch.appendingPathComponent("types.tar")
            try tar.write(to: archive)

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            try #require(entries.count == 7, "\(entries)")

            let out = scratch.appendingPathComponent("out")
            let result = extract(archive, into: out)
            #expect(result.outcome.code == .success, "\(result.outcome)")
            #expect(huntTree(out).keys.sorted() == ["file.txt", "suid-file"], "\(huntTree(out))")
            #expect(result.notes.count == 5, "\(result.notes)")
            #expect(try String(contentsOf: target, encoding: .utf8) == "original")
            var metadata = stat()
            #expect(lstat(target.path, &metadata) == 0)
            #expect(metadata.st_nlink == 1)
            #expect(lstat(out.appendingPathComponent("suid-file").path, &metadata) == 0)
            #expect(metadata.st_mode & 0o7000 == 0)
        }
    }

    // MARK: - Collisions

    @Test
    func `A duplicated member keeps the first copy unless replacing was asked for`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("dup.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("dup.txt", Data("first".utf8))
                try writer.addData("dup.txt", Data("second".utf8))
                try writer.addData("DUP.TXT", Data("third".utf8))
                try writer.finish()
            }
            let kept = scratch.appendingPathComponent("kept")
            let first = extract(archive, into: kept)
            #expect(first.outcome.code == .success)
            #expect(first.notes.count == 2, "\(first.notes)")
            #expect(try String(contentsOf: kept.appendingPathComponent("dup.txt"), encoding: .utf8) == "first")

            let replaced = scratch.appendingPathComponent("replaced")
            let second = extract(archive, into: replaced, overwrite: true)
            #expect(second.outcome.code == .success)
            let names = try FileManager.default.contentsOfDirectory(atPath: replaced.path)
            #expect(names.count == 1, "\(names)")
            #expect(!names.contains { $0.hasPrefix(".fila-") })
        }
    }

    /// `Placement` lets a link entry through when replacing was asked for —
    /// `overwrite || !filaExists(target)` — and then creates it with an
    /// operation that never replaces. Extracting the same archive twice with
    /// Replace is the plainest way to meet that.
    @Test
    func `Extracting an archive with a link twice, replacing, succeeds`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("link.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("file.txt", Data("one".utf8))
                try writer.addSymbolicLink("link", target: "file.txt")
                try writer.finish()
            }
            let out = scratch.appendingPathComponent("out")
            let first = extract(archive, into: out, overwrite: true)
            #expect(first.outcome.code == .success)
            let second = extract(archive, into: out, overwrite: true)
            #expect(second.outcome.code == .success, "second pass: \(second.outcome) notes \(second.notes)")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("link").path) == "file.txt")
        }
    }

    @Test
    func `A file entry whose name an earlier entry made a folder is skipped, not a failed job`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("shape.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                try writer.addData("name/child.txt", Data("child".utf8))
                try writer.addData("name", Data("file".utf8))
                try writer.addData("plain", Data("file".utf8))
                try writer.addData("plain/child.txt", Data("child".utf8))
                try writer.addData("after.txt", Data("after".utf8))
                try writer.finish()
            }
            for overwrite in [false, true] {
                let out = scratch.appendingPathComponent("out-\(overwrite)")
                let result = extract(archive, into: out, overwrite: overwrite)
                #expect(try String(contentsOf: out.appendingPathComponent("name/child.txt"), encoding: .utf8) == "child")
                // Replacing a folder with a file is a refusal from the
                // filesystem, which by design stops the job with its errno.
                if !overwrite {
                    #expect(result.outcome.code == .success, "\(result.outcome) \(result.notes)")
                    #expect(try String(contentsOf: out.appendingPathComponent("plain"), encoding: .utf8) == "file")
                    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("after.txt").path))
                }
                let leftovers = huntTree(out).keys.filter { $0.contains(".fila-") }
                #expect(leftovers.isEmpty, "\(leftovers)")
            }
        }
    }

    // MARK: - Organised publication

    /// The sandboxed `.ipa` extracts in-process as `mobile`, not as root, so a
    /// read-only folder at the top of an archive is moved into place by a user
    /// the kernel checks permissions for.
    @Test
    func `A single read-only top-level folder is published beside the archive`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("readonly.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addDirectory("folder", mode: 0o555)
                try writer.addData("folder/inside.txt", Data("inside".utf8), mode: 0o444)
                try writer.finish()
            }
            defer { huntMakeRemovable(scratch) }
            let result = extract(archive, into: scratch, organize: true)
            #expect(result.outcome.code == .success, "\(result.outcome) \(result.notes)")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.hasPrefix(".fila-") }
            #expect(leftovers.isEmpty, "\(leftovers)")
            #expect(
                FileManager.default.fileExists(atPath: scratch.appendingPathComponent("folder/inside.txt").path),
                "\((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])",
            )

            // The same archive into an explicit destination, where nothing is
            // moved afterwards, extracts fine: the move is what fails.
            let plain = scratch.appendingPathComponent("plain")
            #expect(extract(archive, into: plain).outcome.code == .success)
            #expect(FileManager.default.fileExists(atPath: plain.appendingPathComponent("folder/inside.txt").path))
        }
    }

    @Test
    func `Repeated organised extraction numbers its results and leaves no workspace`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("pack.tar.gz")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tarGzip)
                try writer.addData("a.txt", Data("a".utf8))
                try writer.addData("b.txt", Data("b".utf8))
                try writer.finish()
            }
            for _ in 0 ..< 3 {
                #expect(extract(archive, into: scratch, organize: true).outcome.code == .success)
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
            #expect(names == ["pack", "pack 2", "pack 3", "pack.tar.gz"], "\(names)")
        }
    }

    // MARK: - Volume

    @Test
    func `Twenty thousand members extract in bounded time`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("many.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                for index in 0 ..< 20000 {
                    try writer.addData("d\(index % 50)/f\(index)", Data("\(index)".utf8))
                }
                try writer.finish()
            }
            let out = scratch.appendingPathComponent("out")
            let clock = ContinuousClock()
            let started = clock.now
            let result = extract(archive, into: out)
            let elapsed = clock.now - started
            #expect(result.outcome.code == .success)
            #expect(elapsed < .seconds(60), "\(elapsed)")
            #expect(huntTree(out).count == 20050)
        }
    }

    @Test
    func `More members than the entry limit stops the job rather than running on`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("limit.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                for index in 0 ... ArchiveReader.maximumEntryCount {
                    try writer.addDirectory("d\(index)")
                }
                try writer.finish()
            }
            let result = extract(archive, into: scratch, organize: true)
            #expect(result.outcome.code != .success)
            #expect(result.outcome.systemError == E2BIG, "\(result.outcome)")
            // Organised: the private workspace is discarded with everything in it.
            let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            #expect(names == ["limit.tar"], "\(names)")
        }
    }

    // MARK: - Cancellation

    @Test(arguments: [false, true])
    func `Cancelling at the first report leaves no temporary and, organised, nothing at all`(organize: Bool) throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("cancel.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("big.bin", samplePayload(byteCount: 3_000_000))
                for index in 0 ..< 20 {
                    try writer.addData("small-\(index).txt", Data("\(index)".utf8))
                }
                try writer.finish()
            }
            let destination = organize ? scratch : scratch.appendingPathComponent("out")
            let result = run(
                JobRequest(
                    kind: .extract,
                    sources: [archive.path],
                    destination: destination.path,
                    archive: ArchiveOptions(organizeExtraction: organize),
                ),
                onProgress: { job, _ in job.cancel() },
            )
            #expect(result.outcome.code == .cancelled, "\(result.outcome)")
            let leftovers = huntTree(scratch).keys.filter { $0.contains(".fila-") }
            #expect(leftovers.isEmpty, "\(leftovers)")
            if organize {
                #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["cancel.zip"])
            }
        }
    }

    @Test
    func `Cancelling from another thread mid-member stops and cleans up`() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("slow.tar.xz")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tarXz)
                try writer.addData("one.bin", samplePayload(byteCount: 6_000_000))
                try writer.addData("two.bin", samplePayload(byteCount: 6_000_000))
                try writer.finish()
            }
            let job = ArchiveJob(
                request: JobRequest(
                    kind: .extract,
                    sources: [archive.path],
                    destination: scratch.path,
                    archive: ArchiveOptions(organizeExtraction: true),
                ),
                operations: operations,
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) { job.cancel() }
            let outcome = job.run { _ in }
            if outcome.code == .cancelled {
                #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["slow.tar.xz"])
            } else {
                #expect(outcome.code == .success, "\(outcome)")
            }
            let leftovers = huntTree(scratch).keys.filter { $0.contains(".fila-") }
            #expect(leftovers.isEmpty, "\(leftovers)")
        }
    }

    // MARK: - Round trip

    private func makeAwkwardTree(at tree: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: tree.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
        try manager.createDirectory(at: tree.appendingPathComponent("links"), withIntermediateDirectories: true)
        var nested = tree
        for level in 0 ..< 30 {
            nested = nested.appendingPathComponent("d\(level)")
        }
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("leaf".utf8).write(to: nested.appendingPathComponent("leaf.txt"))
        let files: [(String, Data, Int)] = [
            ("中文 名.txt", Data("中文".utf8), 0o644),
            ("e\u{301}cole.txt", Data("nfd".utf8), 0o644),
            ("emoji 🧪.bin", samplePayload(byteCount: 70000), 0o644),
            ("-leading-dash", Data("dash".utf8), 0o644),
            ("back\\slash.txt", Data("slash".utf8), 0o644),
            ("new\nline.txt", Data("line".utf8), 0o644),
            ("zero.bin", Data(), 0o644),
            ("private.txt", Data("secret".utf8), 0o600),
            ("exec.sh", Data("#!/bin/sh\n".utf8), 0o755),
            (String(repeating: "n", count: 255), Data("long".utf8), 0o644),
            ("..hidden", Data("dots".utf8), 0o644),
        ]
        for (name, data, mode) in files {
            let url = tree.appendingPathComponent(name)
            try data.write(to: url)
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try manager.createSymbolicLink(atPath: tree.appendingPathComponent("links/relative").path, withDestinationPath: "../中文 名.txt")
        try manager.createSymbolicLink(atPath: tree.appendingPathComponent("links/dangling").path, withDestinationPath: "nowhere/at/all")
        try manager.createSymbolicLink(atPath: tree.appendingPathComponent("links/absolute").path, withDestinationPath: "/usr/lib")
    }

    /// Type, permission bits, and content or link target, per relative path.
    private func manifest(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for (path, type) in huntTree(root) {
            let url = root.appendingPathComponent(path)
            var metadata = stat()
            _ = lstat(url.path, &metadata)
            let mode = String(metadata.st_mode & 0o7777, radix: 8)
            switch type {
            case .typeSymbolicLink:
                result[path] = "link → " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory:
                result[path] = "dir \(mode)"
            default:
                let data = try Data(contentsOf: url)
                result[path] = "file \(mode) \(data.count) \(data.hashValue)"
            }
        }
        return result
    }

    @Test(arguments: [ArchiveFormat.zip, .tarGzip, .tar, .tarZstd])
    func `An awkward tree survives compress then extract unchanged`(format: ArchiveFormat) throws {
        try withScratch { scratch in
            let tree = scratch.appendingPathComponent("tree")
            try makeAwkwardTree(at: tree)
            let archive = scratch.appendingPathComponent("tree." + format.filenameExtension)
            let compressed = run(JobRequest(
                kind: .compress,
                sources: [tree.path],
                destination: archive.path,
                archive: ArchiveOptions(format: format),
            ))
            try #require(compressed.outcome.code == .success, "\(compressed.outcome)")
            let out = scratch.appendingPathComponent("out")
            let extracted = extract(archive, into: out)
            #expect(extracted.outcome.code == .success, "\(extracted.outcome) \(extracted.notes)")
            #expect(extracted.notes.isEmpty, "\(extracted.notes)")
            let original = try manifest(tree)
            let restored = try manifest(out.appendingPathComponent("tree"))
            #expect(Set(original.keys) == Set(restored.keys), "missing \(Set(original.keys).subtracting(restored.keys)) extra \(Set(restored.keys).subtracting(original.keys))")
            for (path, expected) in original {
                #expect(restored[path] == expected, "\(format) \(path)")
            }
        }
    }

    // MARK: - Compress refusals

    @Test
    func `A tree holding a fifo refuses to compress and leaves no archive or temporary`() throws {
        try withScratch { scratch in
            let tree = scratch.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: tree.appendingPathComponent("a.txt"))
            #expect(mkfifo(tree.appendingPathComponent("pipe").path, 0o600) == 0)
            let archive = scratch.appendingPathComponent("tree.zip")
            let result = run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: ArchiveOptions()))
            #expect(result.outcome.code != .success)
            #expect(result.outcome.systemError == EFTYPE, "\(result.outcome)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["tree"])
        }
    }

    @Test
    func `Compressing onto an existing name refuses and leaves that file alone`() throws {
        try withScratch { scratch in
            let source = scratch.appendingPathComponent("a.txt")
            try Data("a".utf8).write(to: source)
            let archive = scratch.appendingPathComponent("existing.zip")
            try Data("not mine".utf8).write(to: archive)
            let result = run(JobRequest(kind: .compress, sources: [source.path], destination: archive.path, archive: ArchiveOptions()))
            #expect(result.outcome.systemError == EEXIST, "\(result.outcome)")
            #expect(try String(contentsOf: archive, encoding: .utf8) == "not mine")
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["a.txt", "existing.zip"])
        }
    }

    @Test(arguments: [ZipEncryption.zipCrypto, .aes256])
    func `A locked zip round trips a tree with awkward names`(encryption: ZipEncryption) throws {
        try withScratch { scratch in
            let tree = scratch.appendingPathComponent("tree")
            try makeAwkwardTree(at: tree)
            let archive = scratch.appendingPathComponent("locked.zip")
            let options = ArchiveOptions(format: .zip, encryption: encryption, password: "pässwörd 🔑")
            let compressed = run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: options))
            try #require(compressed.outcome.code == .success, "\(compressed.outcome)")
            let out = scratch.appendingPathComponent("out")
            let extracted = run(JobRequest(
                kind: .extract, sources: [archive.path], destination: out.path,
                archive: ArchiveOptions(password: "pässwörd 🔑"),
            ))
            #expect(extracted.outcome.code == .success, "\(extracted.outcome)")
            #expect(try manifest(tree) == manifest(out.appendingPathComponent("tree")))
        }
    }

    // MARK: - Damaged input

    private func containedExtraction(of bytes: Data, in scratch: URL, label: String) throws {
        let archive = scratch.appendingPathComponent("fuzz.bin")
        try bytes.write(to: archive)
        let before = huntTree(scratch)
        let out = scratch.appendingPathComponent("fuzz-out")
        let result = extract(archive, into: out)
        // Damaged headers can carry any mode; open them up before looking.
        huntMakeRemovable(out)
        let stray = strays(in: scratch, before: before, allowed: ["fuzz-out"])
        #expect(stray.isEmpty, "\(label): \(stray)")
        let leftovers = huntTree(out).keys.filter { $0.contains(".fila-") }
        #expect(leftovers.isEmpty, "\(label): \(leftovers) \(result.outcome)")
        try? FileManager.default.removeItem(at: out)
        #expect(!FileManager.default.fileExists(atPath: out.path), "\(label): could not remove \(out.path)")
    }

    private func fuzzSeed(format: ArchiveFormat, in scratch: URL) throws -> Data {
        let archive = scratch.appendingPathComponent("seed." + format.filenameExtension)
        try withDescriptor(writing: archive) { descriptor in
            let writer = try ArchiveWriter(descriptor: descriptor, format: format)
            try writer.addDirectory("dir")
            try writer.addData("dir/a.txt", Data("alpha".utf8))
            try writer.addData("dir/b.bin", samplePayload(byteCount: 9000))
            try writer.addSymbolicLink("dir/link", target: "a.txt")
            try writer.addData("top.txt", Data("top".utf8))
            try writer.finish()
        }
        defer { try? FileManager.default.removeItem(at: archive) }
        return try Data(contentsOf: archive)
    }

    @Test(arguments: [ArchiveFormat.zip, .tar, .tarGzip])
    func `Randomly damaged archives fail or extract, and stay contained`(format: ArchiveFormat) throws {
        try withScratch { scratch in
            let seed = try fuzzSeed(format: format, in: scratch)
            var random = HuntRandom(seed: 0xF11A_0000 + UInt64(format.filenameExtension.count))
            for iteration in 0 ..< 600 {
                var bytes = seed
                for _ in 0 ... Int.random(in: 0 ..< 6, using: &random) {
                    let at = Int.random(in: 0 ..< bytes.count, using: &random)
                    bytes[at] = UInt8.random(in: 0 ... 255, using: &random)
                }
                try containedExtraction(of: bytes, in: scratch, label: "\(format) #\(iteration)")
            }
        }
    }

    @Test(arguments: [ArchiveFormat.zip, .tarGzip])
    func `Truncated archives fail or extract, and stay contained`(format: ArchiveFormat) throws {
        try withScratch { scratch in
            let seed = try fuzzSeed(format: format, in: scratch)
            for length in stride(from: 0, to: seed.count, by: max(1, seed.count / 120)) {
                try containedExtraction(of: seed.prefix(length), in: scratch, label: "\(format) at \(length)")
            }
        }
    }
}
