@testable import FilaFormats
import Foundation
import Testing

/// Damaged Mach-O files on a jailbroken filesystem are ordinary: a binary
/// half-copied, a slice stripped by hand, a signature truncated by a bad
/// `ldid`. Every one must come back as an error, never a trap or a hang.
@Suite("Stress hunt: Mach-O", .serialized)
struct StressHuntMachOTests {
    /// Everything the properties screen and the inspector ask of a file.
    @discardableResult
    static func exercise(_ url: URL) -> Int {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return 0 }
        defer { close(descriptor) }
        guard let image = try? MachOImage(descriptor: descriptor) else { return 0 }
        for slice in image.slices {
            _ = try? image.inspect(slice)
            _ = try? image.entitlements(of: slice)
        }
        return image.slices.count
    }

    private static func sample() -> URL? {
        for path in ["/usr/libexec/lsd", "/bin/ls"] where FileManager.default.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The ranges a parser actually reads: each slice's header and load
    /// commands, the start of its signature, and the fat header.
    private static func interestingRanges(of url: URL) throws -> [Range<Int>] {
        try withDescriptor(reading: url) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            var ranges: [Range<Int>] = []
            if image.isUniversal {
                ranges.append(0 ..< 8 + image.slices.count * 20)
            }
            let reader = try DescriptorReader(descriptor: descriptor)
            for slice in image.slices {
                let header = try reader.read(at: slice.offset, count: 32)
                let commands: UInt32 = try header.littleEndian(at: 20)
                let start = Int(slice.offset)
                ranges.append(start ..< start + 32 + Int(commands))
                if let signature = slice.signature {
                    let signatureStart = Int(signature.offset)
                    ranges.append(signatureStart ..< signatureStart + Int(min(signature.byteCount, 4096)))
                }
            }
            return ranges
        }
    }

    @Test
    func `Random damage to headers, load commands and signatures never traps`() throws {
        let source = try #require(Self.sample())
        let original = try Data(contentsOf: source)
        let ranges = try Self.interestingRanges(of: source)
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("mutant")
            let interesting: [UInt32] = [0, 1, 7, 8, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0xFFFF_FFF8, UInt32(original.count)]
            var random = HuntRandom(seed: 0x0AC_40)
            let clock = ContinuousClock()
            for iteration in 0 ..< 4000 {
                var bytes = original
                for _ in 0 ... Int.random(in: 0 ..< 4, using: &random) {
                    let range = ranges.randomElement(using: &random)!
                    var at = Int.random(in: range, using: &random)
                    if Bool.random(using: &random), at + 4 <= bytes.count {
                        at &= ~3
                        var word = interesting.randomElement(using: &random)!
                        if Bool.random(using: &random) {
                            word = word.byteSwapped
                        }
                        withUnsafeBytes(of: word) { bytes.replaceSubrange(at ..< at + 4, with: $0) }
                    } else {
                        bytes[at] = UInt8.random(in: 0 ... 255, using: &random)
                    }
                }
                try bytes.write(to: url)
                let started = clock.now
                Self.exercise(url)
                #expect(clock.now - started < .seconds(2), "iteration \(iteration) was slow")
            }
        }
    }

    @Test
    func `A thin slice truncated at every load command boundary fails cleanly`() throws {
        let source = try #require(Self.sample())
        let original = try Data(contentsOf: source)
        let (thin, slice) = try withDescriptor(reading: source) { descriptor -> (Data, MachOImage.Slice) in
            let image = try MachOImage(descriptor: descriptor)
            let slice = try #require(image.slices.last)
            let start = Int(slice.offset)
            return (original.subdata(in: start ..< start + Int(slice.byteCount)), slice)
        }
        // Command boundaries, walked directly from the bytes.
        let commandCount = try Int(thin.littleEndian(at: 16) as UInt32)
        var boundaries = [0, 4, 27, 28, 31, 32]
        var cursor = 32
        for _ in 0 ..< commandCount {
            let size = try Int(thin.littleEndian(at: cursor + 4) as UInt32)
            cursor += size
            boundaries.append(cursor)
        }
        if let signature = slice.signature {
            let start = Int(signature.offset - slice.offset)
            boundaries += [start, start + 8, start + 12, start + 64, start + 1024, Int(slice.byteCount) - 1]
        }
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("thin")
            for boundary in Set(boundaries.flatMap { [$0 - 1, $0, $0 + 1] }).sorted() where boundary >= 0 && boundary <= thin.count {
                try thin.prefix(boundary).write(to: url)
                Self.exercise(url)
            }
            // The whole slice still parses on its own.
            try thin.write(to: url)
            #expect(Self.exercise(url) == 1)
        }
    }

    @Test
    func `A fat file cut anywhere in its first slices fails cleanly`() throws {
        let source = try #require(Self.sample())
        let original = try Data(contentsOf: source)
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("cut")
            for length in stride(from: 0, to: min(original.count, 200_000), by: 509) {
                try original.prefix(length).write(to: url)
                Self.exercise(url)
            }
        }
    }

    /// A synthetic image with one load command whose fields are all at their
    /// extremes, for each command the inspector decodes.
    static let commands: [UInt32] = [
        0x1, 0x19, 0x2, 0x21, 0x2C, 0x24, 0x25, 0x2F, 0x30, 0x32, 0x2A, 0x8000_0028, 0x8000_001C, 0x1D, 0x0C, 0x0D, 0x1B,
    ]

    @Test(arguments: commands)
    func `A load command with extreme fields is refused or summarised, never trusted`(command: UInt32) throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("synthetic")
            for size in [8, 16, 24, 56, 72, 80] {
                for fill in [UInt8(0x00), 0xFF, 0x7F] {
                    var body = Data(repeating: fill, count: size)
                    withUnsafeBytes(of: command.littleEndian) { body.replaceSubrange(0 ..< 4, with: $0) }
                    withUnsafeBytes(of: UInt32(size).littleEndian) { body.replaceSubrange(4 ..< 8, with: $0) }
                    var header = Data()
                    for word: UInt32 in [0xFEED_FACF, 0x0100_000C, 0, 2, 1, UInt32(size), 0, 0] {
                        withUnsafeBytes(of: word.littleEndian) { header.append(contentsOf: $0) }
                    }
                    try (header + body + Data(repeating: fill, count: 4096)).write(to: url)
                    Self.exercise(url)
                }
            }
        }
    }
}
