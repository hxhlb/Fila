@testable import FilaFormats
import Foundation
import Testing

/// What a save does to the parts of a document the user did not touch.
@Suite("Stress hunt: property lists")
struct StressHuntPropertyListTests {
    private static func xmlDocument(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(body)
        </plist>
        """.utf8)
    }

    private static func reparsed(_ data: Data) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: - Integers outside Int64

    /// `<integer>` holds any value from Int64.min to UInt64.max, and
    /// Foundation reads the upper half. An edit to a different key must not
    /// rewrite it: the document keeps it, or refuses to open or to save.
    @Test(arguments: [PropertyListDocument.Format.xml, .binary])
    func `An unsigned integer above Int64.max survives an edit elsewhere or is refused`(
        format: PropertyListDocument.Format,
    ) throws {
        let xml = Self.xmlDocument("""
        <dict>
            <key>Big</key>
            <integer>18446744073709551615</integer>
            <key>Label</key>
            <string>before</string>
        </dict>
        """)
        let source: Data
        if format == .binary {
            let object = try PropertyListSerialization.propertyList(from: xml, format: nil)
            source = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        } else {
            source = xml
        }
        // Foundation itself keeps the value: the original bytes are fine.
        let original = try Self.reparsed(source)
        try #require((original["Big"] as? NSNumber)?.stringValue == "18446744073709551615")

        var document: PropertyListDocument
        do {
            document = try PropertyListDocument(data: source)
        } catch FormatFailure.unsupported {
            return // Refusing to open loses nothing.
        }
        #expect(document.format == format)
        document.root[[.key("Label")]] = .string("after")
        let saved: Data
        do {
            saved = try document.serialized()
        } catch FormatFailure.unsupported {
            return // Refusing to save loses nothing either.
        }
        let restored = try Self.reparsed(saved)
        #expect(restored["Label"] as? String == "after")
        #expect(
            (restored["Big"] as? NSNumber)?.stringValue == "18446744073709551615",
            "Big read back as \(String(describing: document.root[[.key("Big")]])), saved as \(restored["Big"] ?? "nothing")",
        )
    }

    // MARK: - Strings

    static let awkwardScalars: [UInt32] = Array(0 ... 0x1F) + [0x7F, 0x85, 0xA0, 0x2028, 0xFFFE, 0xFFFF, 0x1F9EA]

    /// A binary plist may hold any string. Converting it to XML — the edit the
    /// browser offers — must produce bytes that read back as the same string,
    /// or fail before anything is written: a saved file that no longer parses
    /// is a launchd job that no longer loads.
    @Test(arguments: awkwardScalars)
    func `A string with an awkward character round trips through XML or refuses to save`(scalar: UInt32) throws {
        let character = String(Character(Unicode.Scalar(scalar)!))
        let value = PropertyListValue.dictionary([
            "Text": .string("a" + character + "b"),
            "Key" + character: .integer(1),
        ])
        for format in [PropertyListDocument.Format.binary, .xml] {
            let saved: Data
            do {
                saved = try PropertyListDocument(root: value, format: format).serialized()
            } catch {
                continue // Refusing to save loses nothing.
            }
            let restored: PropertyListDocument
            do {
                restored = try PropertyListDocument(data: saved)
            } catch {
                Issue.record("U+\(String(scalar, radix: 16)) as \(format): saved bytes no longer parse (\(error))")
                continue
            }
            #expect(restored.root == value, "U+\(String(scalar, radix: 16)) as \(format)")
        }
    }

    @Test
    func `Line endings inside a string are kept through XML`() throws {
        let value = PropertyListValue.dictionary(["Text": .string("one\r\ntwo\rthree\n")])
        let restored = try PropertyListDocument(data: PropertyListDocument(root: value, format: .xml).serialized())
        #expect(restored.root == value)
    }

    // MARK: - Numbers and dates

    static let awkwardReals: [UInt64] = [
        0.1, 1.0 / 3.0, -0.0, 5e-324, 2.2250738585072014e-308, 1e308, Double.greatestFiniteMagnitude,
        Double.infinity, -Double.infinity, Double.nan, 123_456_789_012_345_678.0,
    ].map(\.bitPattern)

    @Test(arguments: awkwardReals)
    func `A real keeps its exact bits in both formats`(bits: UInt64) throws {
        let number = Double(bitPattern: bits)
        for format in [PropertyListDocument.Format.binary, .xml] {
            let saved = try PropertyListDocument(root: .array([.real(number)]), format: format).serialized()
            let restored = try PropertyListDocument(data: saved)
            guard case let .array(values) = restored.root, case let .real(back) = values.first else {
                Issue.record("\(number) as \(format) came back as \(restored.root)")
                continue
            }
            if number.isNaN {
                #expect(back.isNaN, "\(format)")
            } else if number == 0, format == .xml {
                // Foundation's XML writer drops the sign of zero; equal by value.
                #expect(back == number)
            } else {
                #expect(back.bitPattern == number.bitPattern, "\(number) as \(format) came back as \(back)")
            }
        }
    }

    static let awkwardIntegers: [Int64] = [.min, -9_223_372_036_854_775_807, -1, 0, 1, 2_147_483_648, .max]

    @Test(arguments: awkwardIntegers)
    func `An integer keeps its value and its type in both formats`(number: Int64) throws {
        for format in [PropertyListDocument.Format.binary, .xml] {
            let value = PropertyListValue.array([.integer(number)])
            let restored = try PropertyListDocument(data: PropertyListDocument(root: value, format: format).serialized())
            #expect(restored.root == value, "\(number) as \(format)")
        }
    }

    @Test(arguments: [
        Date.distantPast, Date.distantFuture, Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -1),
        Date(timeIntervalSinceReferenceDate: -63_113_904_000), Date(timeIntervalSinceReferenceDate: 3e11),
    ])
    func `A whole-second date survives both formats`(date: Date) throws {
        for format in [PropertyListDocument.Format.binary, .xml] {
            let value = PropertyListValue.array([.date(date)])
            let saved: Data
            do {
                saved = try PropertyListDocument(root: value, format: format).serialized()
            } catch {
                continue
            }
            let restored: PropertyListDocument
            do {
                restored = try PropertyListDocument(data: saved)
            } catch {
                Issue.record("\(date) as \(format): saved bytes no longer parse (\(error))")
                continue
            }
            #expect(restored.root == value, "\(date.timeIntervalSince1970) as \(format) came back as \(restored.root)")
        }
    }

    // MARK: - Untouched values

    private static var everything: PropertyListValue {
        .dictionary([
            "true": .boolean(true),
            "false": .boolean(false),
            "zero": .integer(0),
            "one": .integer(1),
            "minusOne": .integer(-1),
            "realOne": .real(1),
            "realHalf": .real(0.5),
            "realZero": .real(0),
            "empty": .string(""),
            "unicode": .string("中文 🧪 e\u{301}"),
            "data": .data(Data((0 ... 255).map { UInt8($0) })),
            "emptyData": .data(Data()),
            "date": .date(Date(timeIntervalSince1970: 1_700_000_000)),
            "emptyArray": .array([]),
            "emptyDict": .dictionary([:]),
            "nested": .array([.dictionary(["deep": .array([.integer(7), .real(7), .boolean(true), .string("7")])])]),
            "": .string("empty key"),
            "edited": .string("before"),
        ])
    }

    @Test(arguments: [PropertyListDocument.Format.binary, .xml])
    func `Editing one key leaves every other value and type exactly as it was`(format: PropertyListDocument.Format) throws {
        let source = try PropertyListDocument(root: Self.everything, format: format).serialized()
        var document = try PropertyListDocument(data: source)
        #expect(document.root == Self.everything)
        document.root[[.key("edited")]] = .string("after")
        let restored = try PropertyListDocument(data: document.serialized())
        var expected = Self.everything
        expected[[.key("edited")]] = .string("after")
        #expect(restored.root == expected)
        #expect(restored.format == format)
    }

    /// A `<real>` that holds a whole number has to stay a real, and an
    /// `<integer>` that the reader might take for a boolean has to stay an
    /// integer, when the document was written by someone else.
    @Test
    func `Hand-written XML keeps real, integer and boolean apart through a save`() throws {
        let xml = Self.xmlDocument("""
        <dict>
            <key>r</key><real>1</real>
            <key>i</key><integer>1</integer>
            <key>z</key><integer>0</integer>
            <key>b</key><true/>
            <key>f</key><false/>
            <key>neg</key><real>-0</real>
        </dict>
        """)
        let document = try PropertyListDocument(data: xml)
        #expect(document.root[[.key("r")]] == .real(1))
        #expect(document.root[[.key("i")]] == .integer(1))
        #expect(document.root[[.key("z")]] == .integer(0))
        #expect(document.root[[.key("b")]] == .boolean(true))
        #expect(document.root[[.key("f")]] == .boolean(false))
        for format in [PropertyListDocument.Format.binary, .xml] {
            let restored = try PropertyListDocument(data: document.serialized(as: format))
            #expect(restored.root == document.root, "\(format)")
        }
    }

    // MARK: - Size and depth

    private static func nested(_ depth: Int) -> PropertyListValue {
        var value = PropertyListValue.integer(1)
        for _ in 0 ..< depth {
            value = .array([value])
        }
        return value
    }

    @Test
    func `Nesting is accepted up to the budget and refused one level past it, both ways`() throws {
        let allowed = try PropertyListDocument(root: Self.nested(64), format: .binary).serialized()
        #expect(try PropertyListDocument(data: allowed).root == Self.nested(64))
        #expect(throws: FormatFailure.self) { try PropertyListDocument(root: Self.nested(65), format: .binary).serialized() }
        let deep = try PropertyListSerialization.data(
            fromPropertyList: Self.nested(65).propertyListObject, format: .binary, options: 0,
        )
        #expect(throws: FormatFailure.self) { try PropertyListDocument(data: deep) }
    }

    @Test
    func `More than the node budget is refused before an editor tree is built`() throws {
        let array = (0 ..< 100_001).map { NSNumber(value: $0) }
        let data = try PropertyListSerialization.data(fromPropertyList: array, format: .binary, options: 0)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(throws: FormatFailure.self) { try PropertyListDocument(data: data) }
        #expect(clock.now - started < .seconds(10))
    }

    @Test
    func `A document over the byte budget is refused before it is parsed`() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("huge.plist")
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(PropertyListDocument.maximumByteCount) + 1)
            try handle.close()
            try withDescriptor(reading: url) { descriptor in
                #expect(throws: FormatFailure.self) { try PropertyListDocument(descriptor: descriptor) }
            }
        }
    }

    /// Foundation parses before the budget's depth check sees anything, so
    /// the depth a hostile file reaches is Foundation's recursion, on whatever
    /// stack the caller is on. 512 KB is a secondary thread's stack on iOS.
    static func parseOnSmallStack(_ data: Data) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            _ = try? PropertyListDocument(data: data)
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
    }

    static func deepXML(depth: Int) -> Data {
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">"
        text += String(repeating: "<array>", count: depth)
        text += "<true/>"
        text += String(repeating: "</array>", count: depth)
        text += "</plist>"
        return Data(text.utf8)
    }

    @Test
    func `A deeply nested XML plist the size of an entitlements blob does not take the process down`() async {
        await #expect(processExitsWith: .success) {
            StressHuntPropertyListTests.parseOnSmallStack(StressHuntPropertyListTests.deepXML(depth: 8000))
        }
    }

    @Test
    func `A deeply nested XML plist within the byte budget does not take the process down`() async {
        await #expect(processExitsWith: .success) {
            StressHuntPropertyListTests.parseOnSmallStack(StressHuntPropertyListTests.deepXML(depth: 200_000))
        }
    }

    // MARK: - Damaged binary

    @Test
    func `A randomly damaged binary plist fails as a format failure and never crashes`() throws {
        let seed = try PropertyListDocument(root: Self.everything, format: .binary).serialized()
        var random = HuntRandom(seed: 0xB11_57)
        var parsed = 0
        for _ in 0 ..< 3000 {
            var bytes = seed
            for _ in 0 ... Int.random(in: 0 ..< 4, using: &random) {
                // The trailer and the offset table are at the end, and they
                // are the interesting part.
                let at = Bool.random(using: &random)
                    ? Int.random(in: max(0, bytes.count - 64) ..< bytes.count, using: &random)
                    : Int.random(in: 0 ..< bytes.count, using: &random)
                bytes[at] = UInt8.random(in: 0 ... 255, using: &random)
            }
            do {
                let document = try PropertyListDocument(data: bytes)
                // Whatever parsed has to be writable or refuse to write.
                _ = try? document.serialized()
                parsed += 1
            } catch is FormatFailure {
            } catch {
                Issue.record("unexpected error type \(type(of: error)): \(error)")
            }
        }
        #expect(parsed > 0)
    }

    @Test
    func `A truncated binary plist fails at every length`() throws {
        let seed = try PropertyListDocument(root: Self.everything, format: .binary).serialized()
        // Up to the eight-byte magic the prefix is plain ASCII, which is a
        // valid OpenStep string — Foundation is right to read it as one.
        for length in 9 ..< seed.count {
            #expect(throws: FormatFailure.self) { try PropertyListDocument(data: seed.prefix(length)) }
        }
    }

    /// A keyed archive is a binary plist holding `CF$UID` values, which have
    /// no case here. Opening one must be a refusal, not a crash or a
    /// silently rewritten file.
    @Test
    func `A keyed archive is refused rather than rewritten`() throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: ["key": [1, 2, 3]] as NSDictionary, requiringSecureCoding: false)
        #expect(throws: FormatFailure.self) { try PropertyListDocument(data: data) }
    }

    // MARK: - Paths

    @Test
    func `Hostile paths through the editor subscript change nothing and never trap`() {
        var root = Self.everything
        let paths: [[PropertyListPathComponent]] = [
            [.index(-1)], [.index(Int.max)], [.index(Int.min)],
            [.key("nested"), .index(-1)], [.key("nested"), .index(Int.max), .key("deep")],
            [.key("nested"), .index(0), .key("deep"), .index(-5)],
            [.key("true"), .key("x")], [.key("data"), .index(0)],
        ]
        for path in paths {
            #expect(root[path] == nil, "\(path)")
            root[path] = .string("x")
            root[path] = nil
        }
        #expect(root == Self.everything)
    }
}
