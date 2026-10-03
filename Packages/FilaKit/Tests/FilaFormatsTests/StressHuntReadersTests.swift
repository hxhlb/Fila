import CryptoKit
@testable import FilaFormats
import FilaProtocol
import Foundation
import Testing

@Suite("Stress hunt: hex windows")
struct StressHuntHexWindowTests {
    @Test
    func `Reads at the edges of the file clamp and never fail`() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("blob.bin")
            let payload = samplePayload(byteCount: 1000)
            try payload.write(to: url)
            try withDescriptor(reading: url) { descriptor in
                let window = try HexWindow(descriptor: descriptor)
                let end = window.byteCount
                #expect(try window.read(at: 0, count: 1) == payload.prefix(1))
                #expect(try window.read(at: end - 1, count: 16) == payload.suffix(1))
                #expect(try window.read(at: end, count: 16).isEmpty)
                #expect(try window.read(at: end + 1, count: 16).isEmpty)
                #expect(try window.read(at: .max, count: 16).isEmpty)
                #expect(try window.read(at: .min, count: 16).isEmpty)
                #expect(try window.read(at: -1, count: 16).isEmpty)
                #expect(try window.read(at: 0, count: .max) == payload)
                #expect(try window.read(at: 0, count: 0).isEmpty)
                #expect(try window.read(at: 0, count: -1).isEmpty)
                #expect(try window.read(at: 0, count: .min).isEmpty)
                #expect(try window.rows(0 ..< 1) == payload.prefix(16))
                #expect(try window.rows(62 ..< 63) == payload[992 ..< 1000])
                #expect(try window.rows(63 ..< 64).isEmpty)
                #expect(try window.rows(0 ..< 0).isEmpty)
                #expect(try window.rows(0 ..< 1, bytesPerRow: 0).isEmpty)
                #expect(try window.rows(0 ..< 1, bytesPerRow: -16).isEmpty)
                #expect(window.rowCount(bytesPerRow: 0) == 0)
                #expect(window.rowCount(bytesPerRow: -1) == 0)
                #expect(window.rowCount(bytesPerRow: 7) == 143)
            }
        }
    }

    @Test
    func `An empty file has no rows and no bytes`() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("empty.bin")
            try Data().write(to: url)
            try withDescriptor(reading: url) { descriptor in
                let window = try HexWindow(descriptor: descriptor)
                #expect(window.rowCount() == 0)
                #expect(try window.read(at: 0, count: 16).isEmpty)
                #expect(try window.rows(0 ..< 1).isEmpty)
            }
        }
    }

    @Test
    func `A file truncated under the window reads short rather than failing`() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("shrinking.bin")
            try samplePayload(byteCount: 4096).write(to: url)
            try withDescriptor(reading: url) { descriptor in
                let window = try HexWindow(descriptor: descriptor)
                #expect(truncate(url.path, 100) == 0)
                #expect(try window.read(at: 90, count: 16).count == 10)
                #expect(try window.read(at: 200, count: 16).isEmpty)
                #expect(try window.rows(0 ..< 256).count == 100)
            }
        }
    }

    /// The window's row arithmetic, given a range the caller computed from a
    /// typed offset. Exit tests, so a trap is a failed expectation rather than
    /// the end of the run.
    static func rowsProbe(_ range: Range<Int64>, bytesPerRow: Int = HexWindow.bytesPerRow) {
        let path = NSTemporaryDirectory() + "fila-hunt-hex-\(getpid())"
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: 64))
        let descriptor = open(path, O_RDONLY)
        // Unlinked before the call under test: a trap skips every defer.
        unlink(path)
        defer { close(descriptor) }
        guard let window = try? HexWindow(descriptor: descriptor) else { exit(2) }
        _ = try? window.rows(range, bytesPerRow: bytesPerRow)
    }

    static func rowCountProbe(_ bytesPerRow: Int) {
        let path = NSTemporaryDirectory() + "fila-hunt-hex-count-\(getpid())"
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: 64))
        let descriptor = open(path, O_RDONLY)
        unlink(path)
        defer { close(descriptor) }
        guard let window = try? HexWindow(descriptor: descriptor) else { exit(2) }
        _ = window.rowCount(bytesPerRow: bytesPerRow)
    }

    @Test
    func `Asking for every row there could be does not trap`() async {
        await #expect(processExitsWith: .success) {
            StressHuntHexWindowTests.rowsProbe(0 ..< Int64.max)
        }
    }

    @Test
    func `Asking for the last possible row does not trap`() async {
        await #expect(processExitsWith: .success) {
            StressHuntHexWindowTests.rowsProbe(Int64.max - 1 ..< Int64.max)
        }
    }

    @Test
    func `A very wide row does not trap the row count`() async {
        await #expect(processExitsWith: .success) {
            StressHuntHexWindowTests.rowCountProbe(Int.max)
        }
    }

    @Test
    func `Offsets typed by a person parse or are refused, never trap`() {
        var random = HuntRandom(seed: 0x4E7)
        let alphabet = Array("0123456789abcdefxX -+_\n\t٣０".unicodeScalars)
        for _ in 0 ..< 20000 {
            let length = Int.random(in: 0 ..< 24, using: &random)
            var text = String.UnicodeScalarView()
            for _ in 0 ..< length {
                text.append(alphabet.randomElement(using: &random)!)
            }
            if let offset = HexWindow.parseOffset(String(text)) {
                #expect(offset >= 0)
            }
        }
        #expect(HexWindow.parseOffset("0x7fffffffffffffff") == .max)
        #expect(HexWindow.parseOffset("-0") == 0)
    }
}

@Suite("Stress hunt: format detection")
struct StressHuntFileFormatTests {
    private static let names = [
        "", ".", "..", "/", "a.", ".plist", "x.PLIST", "x.DocX", "README.doc", "a.tar.gz", "noextension",
        "dots...", "trailing.", "很长的名字.txt", "e\u{301}.json", String(repeating: "a", count: 10000) + ".zip",
        "name.\u{0}", "a.b/c", "x." + String(repeating: "z", count: 300), "🧪.🧪", "x.key", "x.pages", "x.rtf",
    ]

    @Test
    func `Random heads and awkward names always detect as something`() {
        var random = HuntRandom(seed: 0xDE7EC7)
        let prefixes: [[UInt8]] = [
            [], Array("bplist".utf8), Array("<?xml version=\"1.0\"?>".utf8), Array("<plist".utf8),
            Array("<!DOCTYPE plist [".utf8), [0x50, 0x4B, 0x03, 0x04], [0xCF, 0xFA, 0xED, 0xFE],
            [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], Array("{\\rtf".utf8), [0xEF, 0xBB, 0xBF],
        ]
        for _ in 0 ..< 4000 {
            var head = Data(prefixes.randomElement(using: &random)!)
            let extra = Int.random(in: 0 ..< 700, using: &random)
            head.append(contentsOf: (0 ..< extra).map { _ in UInt8.random(in: 0 ... 255, using: &random) })
            let name = Self.names.randomElement(using: &random)!
            _ = FileFormat.detect(head: head, name: name)
            _ = FileFormat.detect(name: name)
            _ = FileFormat.documentMIMEType(name: name)
        }
    }

    @Test
    func `A head sliced out of a larger buffer detects the same as a fresh copy`() {
        var tar = Data(count: 600)
        tar.replaceSubrange(257 ..< 262, with: Array("ustar".utf8))
        let framed = Data([1, 2, 3]) + tar
        let slice = framed[3...]
        #expect(FileFormat.detect(head: Data(slice), name: "data") == .archive)
        #expect(FileFormat.detect(head: slice, name: "data") == .archive)
        #expect(FileFormat.detect(head: Data("bplist00".utf8)[2...], name: "x") == FileFormat.detect(head: Data("list00".utf8), name: "x"))
    }

    @Test
    func `An XML head that is not a plist, or never closes, is not a property list`() {
        let heads = [
            "<?xml version=\"1.0\"?><caml/>",
            "<?xml version=\"1.0\"?><!-- " + String(repeating: "x", count: 600),
            "<?xml version=\"1.0\"?><!DOCTYPE plist><notplist/>",
            "<?xml version=\"1.0\"?>" + String(repeating: "<a>", count: 200),
        ]
        for head in heads {
            #expect(FileFormat.detect(head: Data(head.utf8), name: "file") != .propertyList, "\(head.prefix(60))")
        }
        #expect(FileFormat.detect(head: Data("<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict/></plist>".utf8), name: "f") == .propertyList)
    }
}

@Suite("Stress hunt: checksums")
struct StressHuntChecksumTests {
    private func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static let sizes: [Int] = [0, 1, 261_120, 262_143, 262_144, 262_145, 786_439]

    @Test(arguments: sizes)
    func `Every size across the buffer edge hashes like CryptoKit over the whole file`(byteCount: Int) throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("payload")
            let payload = samplePayload(byteCount: byteCount)
            try payload.write(to: url)
            let sums = try withDescriptor(reading: url) { try FileChecksums.read(descriptor: $0) }
            #expect(sums.md5 == hex(Insecure.MD5.hash(data: payload)))
            #expect(sums.sha1 == hex(Insecure.SHA1.hash(data: payload)))
            #expect(sums.sha256 == hex(SHA256.hash(data: payload)))
        }
    }

    @Test
    func `A fifo, a directory and a closed descriptor are refused`() throws {
        try withScratch { scratch in
            let fifo = scratch.appendingPathComponent("fifo")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            let reader = open(fifo.path, O_RDONLY | O_NONBLOCK)
            #expect(reader >= 0)
            defer { close(reader) }
            #expect(throws: (any Error).self) { try FileChecksums.read(descriptor: reader) }

            let directory = open(scratch.path, O_RDONLY)
            defer { close(directory) }
            #expect(throws: (any Error).self) { try FileChecksums.read(descriptor: directory) }

            #expect(throws: (any Error).self) { try FileChecksums.read(descriptor: -1) }
        }
    }

    @Test
    func `A cancelled task stops hashing`() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fila-hunt-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("payload")
        try samplePayload(byteCount: 1_000_000).write(to: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try withDescriptor(reading: url) { try FileChecksums.read(descriptor: $0) }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("Stress hunt: budgets")
struct StressHuntBudgetTests {
    @Test
    func `Byte budgets reject negative and oversize counts for every format`() {
        for format in FileFormat.allCases {
            #expect(throws: FormatFailure.self) { try PreviewLimits.validate(byteCount: -1, format: format) }
            #expect(throws: Never.self) { try PreviewLimits.validate(byteCount: 0, format: format) }
        }
        #expect(throws: FormatFailure.self) { try PreviewLimits.validate(byteCount: .max, format: .archive) }
        #expect(throws: FormatFailure.self) { try PreviewLimits.validate(byteCount: .max, format: .propertyList) }
        #expect(throws: FormatFailure.self) { try PreviewLimits.validate(byteCount: .max, format: .pdf) }
    }

    @Test
    func `The text line budget stops at the hundred-thousandth break for every line ending`() {
        for ending in ["\n", "\r", "\r\n"] {
            let data = Data(String(repeating: "x" + ending, count: 150_000).utf8)
            let cut = PreviewLimits.textPrefixByteCount(data)
            let lines = String(decoding: data.prefix(cut), as: UTF8.self)
                .components(separatedBy: ending).count
            #expect(lines == 100_000, "\(ending.debugDescription): cut \(cut) gives \(lines)")
            #expect(cut < data.count)
        }
        #expect(PreviewLimits.textPrefixByteCount(Data()) == 0)
        let slice = Data(String(repeating: "x\n", count: 10).utf8)[4...]
        #expect(PreviewLimits.textPrefixByteCount(slice) == slice.count)
    }

    @Test
    func `A space estimate never overflows, whatever the headers claim`() {
        let entries = (0 ..< 4).map {
            ArchiveEntry(declaredPath: "f\($0)", kind: .regular, byteCount: .max, mode: S_IFREG | 0o644)
        } + [ArchiveEntry(declaredPath: "neg", kind: .regular, byteCount: -5, mode: S_IFREG | 0o644)]
        let estimate = ArchiveSpaceEstimate(entries: entries)
        #expect(estimate.byteCount == .max)
        #expect(estimate.hasUnknownSize)
        #expect(estimate.needsWarning(availableByteCount: .max))
        #expect(estimate.needsWarning(availableByteCount: .min))
        #expect(!ArchiveSpaceEstimate(entries: []).needsWarning(availableByteCount: 0))
        #expect(!ArchiveSpaceEstimate(entries: []).needsWarning(availableByteCount: .max))
    }
}
