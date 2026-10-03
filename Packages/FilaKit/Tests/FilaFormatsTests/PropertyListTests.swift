@testable import FilaFormats
import Foundation
import Testing

@Suite("Property lists")
struct PropertyListTests {
    private var mixed: PropertyListValue {
        .dictionary([
            "Label": .string("wiki.qaq.filad"),
            "KeepAlive": .boolean(true),
            "Nice": .integer(-5),
            "ThrottleInterval": .integer(10),
            "Ratio": .real(0.5),
            "Stamp": .date(Date(timeIntervalSince1970: 1_700_000_000)),
            "Blob": .data(Data([0xDE, 0xAD, 0xBE, 0xEF])),
            "ProgramArguments": .array([.string("/usr/libexec/filad"), .integer(1)]),
        ])
    }

    @Test(arguments: [PropertyListDocument.Format.binary, .xml])
    func `Binary and XML both survive a round trip with their types intact`(format: PropertyListDocument.Format) throws {
        let document = PropertyListDocument(root: mixed, format: format)
        let restored = try PropertyListDocument(data: document.serialized())
        #expect(restored.format == format)
        #expect(restored.root == mixed)
    }

    @Test
    func `An integer does not come back as a real, which is what breaks a launchd job`() throws {
        let restored = try PropertyListDocument(data: PropertyListDocument(root: mixed, format: .binary).serialized())
        #expect(restored.root[[.key("Nice")]] == .integer(-5))
        #expect(restored.root[[.key("Ratio")]] == .real(0.5))
        #expect(restored.root[[.key("KeepAlive")]] == .boolean(true))
    }

    @Test
    func `Converting a binary plist to XML and back is the edit a jailbreak user wants`() throws {
        let binary = try PropertyListDocument(root: mixed, format: .binary).serialized()
        var document = try PropertyListDocument(data: binary)
        #expect(document.format == .binary)

        document.format = .xml
        let xml = try document.serialized()
        #expect(String(decoding: xml.prefix(5), as: UTF8.self) == "<?xml")
        #expect(try PropertyListDocument(data: xml).root == mixed)
    }

    @Test
    func `A path addresses a row, and assigning nil removes it`() {
        var root = mixed
        root[[.key("Label")]] = .string("wiki.qaq.other")
        root[[.key("ProgramArguments"), .index(1)]] = .string("--verbose")
        root[[.key("ProgramArguments"), .index(2)]] = .string("--appended")
        root[[.key("Nice")]] = nil

        #expect(root[[.key("Label")]] == .string("wiki.qaq.other"))
        #expect(root[[.key("ProgramArguments")]] == .array([.string("/usr/libexec/filad"), .string("--verbose"), .string("--appended")]))
        #expect(root[[.key("Nice")]] == nil)
    }

    @Test
    func `A path that leads nowhere reads nil and changes nothing`() {
        var root = mixed
        root[[.key("Nice"), .key("deeper")]] = .string("x")
        root[[.key("ProgramArguments"), .index(99)]] = .string("x")
        #expect(root == mixed)
        #expect(root[[.index(0)]] == nil)
    }

    @Test
    func `A plist read from a descriptor is the same one`() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("job.plist")
            try PropertyListDocument(root: mixed, format: .binary).serialized().write(to: url)
            let document = try withDescriptor(reading: url) { try PropertyListDocument(descriptor: $0) }
            #expect(document.format == .binary)
            #expect(document.root == mixed)
        }
    }

    @Test
    func `Anything that is not a property list fails as damaged, not as a crash`() {
        #expect(throws: FormatFailure.self) { try PropertyListDocument(data: Data(repeating: 0xFF, count: 32)) }
    }

    /// Foundation reads `<integer>` up to UInt64.max; `int64Value` would
    /// turn the top of that range negative, and a save would write it so.
    /// The value is kept as its text beside readable siblings, and the
    /// document refuses to be written.
    @Test(arguments: ["18446744073709551615", "9223372036854775808"])
    func `An integer above Int64.max is shown as itself and never written back`(number: String) throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Big</key><integer>\(number)</integer><key>Name</key><string>kept</string></dict></plist>
        """.utf8)
        let binary = try PropertyListSerialization.data(
            fromPropertyList: PropertyListSerialization.propertyList(from: xml, format: nil),
            format: .binary,
            options: 0,
        )
        for data in [xml, binary] {
            let document = try PropertyListDocument(data: data)
            #expect(document.root == .dictionary(["Big": .unrepresentable(number), "Name": .string("kept")]))
            #expect(throws: FormatFailure.self) { try document.serialized() }
        }
        let edges = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array><integer>9223372036854775807</integer><integer>-9223372036854775808</integer></array></plist>
        """.utf8)
        #expect(try PropertyListDocument(data: edges).root == .array([.integer(.max), .integer(.min)]))
    }
}
