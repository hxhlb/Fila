@testable import FilaApplications
import Foundation
import Testing

/// The Install… card names the app installd will register. Every member an
/// extractor would write over `Payload/<app>.app/Info.plist` is a second
/// manifest, however it is spelled.
@Suite("IPA manifest")
struct IPAManifestTests {
    @Test
    func `One Info.plist names the package`() async throws {
        let url = try Self.zip([
            ("Payload/A.app/Info.plist", Self.plist("com.example.game", name: "Game")),
            ("Payload/A.app/A", Data("binary".utf8)),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = try await IPAInstaller.manifest(ofIPAAt: url)
        #expect(manifest.bundleID == "com.example.game")
        #expect(manifest.displayName == "Game")
    }

    @Test(arguments: [
        "Payload/A.app/./Info.plist",
        "Payload/./A.app/Info.plist",
        "./Payload/A.app/Info.plist",
        "Payload//A.app/Info.plist",
        "payload/A.app/info.plist",
        "Payload/B.APP/INFO.PLIST",
    ])
    func `A second spelling of the Info.plist refuses the package`(second: String) async throws {
        let url = try Self.zip([
            ("Payload/A.app/Info.plist", Self.plist("com.example.game", name: "Game")),
            (second, Self.plist("com.example.victim", name: "Victim")),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PackageFailure.self) {
            try await IPAInstaller.manifest(ofIPAAt: url)
        }
    }

    @Test(arguments: ["Payload/A.app/../B.app/Info.plist", "/Payload/A.app/Info.plist", "Payload/A.app/x/../../../etc"])
    func `A member that climbs or starts at the root refuses the package`(member: String) async throws {
        let url = try Self.zip([
            ("Payload/A.app/Info.plist", Self.plist("com.example.game", name: "Game")),
            (member, Data("x".utf8)),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PackageFailure.self) {
            try await IPAInstaller.manifest(ofIPAAt: url)
        }
    }

    @Test
    func `Placed components fold what open folds`() throws {
        #expect(try #require(IPAInstaller.placedComponents(of: "./Payload//A.app/./Info.plist")) == ["Payload", "A.app", "Info.plist"])
        #expect(IPAInstaller.placedComponents(of: "Payload/../Info.plist") == nil)
        #expect(IPAInstaller.placedComponents(of: "/Payload/A.app/Info.plist") == nil)
    }

    /// "/" followed by a combining mark is one `Character` and not "/", but
    /// the kernel splits on the byte.
    @Test
    func `Placed components split where the kernel splits`() throws {
        #expect(try #require(IPAInstaller.placedComponents(of: "Payload/\u{301}B.app/Info.plist"))
            == ["Payload", "\u{301}B.app", "Info.plist"])
        #expect(IPAInstaller.placedComponents(of: "Payload/A.app/../\u{301}x") == nil)
        #expect(IPAInstaller.placedComponents(of: "/\u{301}Payload/A.app/Info.plist") == nil)
    }

    @Test
    func `A second Info.plist behind a combining mark refuses the package`() async throws {
        let url = try Self.zip([
            ("Payload/A.app/Info.plist", Self.plist("com.example.game", name: "Game")),
            ("Payload/\u{301}B.app/Info.plist", Self.plist("com.example.victim", name: "Victim")),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PackageFailure.self) {
            try await IPAInstaller.manifest(ofIPAAt: url)
        }
    }

    /// installd streams the local headers; a member the central directory
    /// does not list is still one it installs.
    @Test(arguments: ["Payload/A.app/Info.plist", "Payload/B.app/Info.plist"])
    func `An Info.plist missing from the central directory refuses the package`(hidden: String) async throws {
        let url = try Self.zip([
            (hidden, Self.plist("com.example.victim", name: "Victim")),
            ("Payload/A.app/Info.plist", Self.plist("com.example.game", name: "Game")),
        ], localOnly: [0])
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PackageFailure.self) {
            try await IPAInstaller.manifest(ofIPAAt: url)
        }
    }

    @Test
    func `A package read by its local headers alone names the same app`() async throws {
        let url = try Self.zip([
            ("Payload/A.app/A", Data("binary".utf8)),
            ("Payload/A.app/Info.plist", Self.plist("com.example.game", name: "Game")),
        ], localOnly: [0])
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = try await IPAInstaller.manifest(ofIPAAt: url)
        #expect(manifest.bundleID == "com.example.game")
    }

    // MARK: - Fixtures

    private static func plist(_ identifier: String, name: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleDisplayName": name], format: .xml, options: 0,
        )
    }

    /// A stored zip written by hand, member names exactly as given: libarchive's
    /// writer folds `.` components away, and these tests are about the names
    /// it would not write.
    ///
    /// The members at `localOnly` positions get a local header and no
    /// central-directory record: what a streaming reader sees and a reader of
    /// the directory does not.
    private static func zip(_ members: [(String, Data)], localOnly: Set<Int> = []) throws -> URL {
        var archive = Data()
        var central = Data()
        var listed = 0
        for (position, (name, data)) in members.enumerated() {
            let offset = UInt32(archive.count)
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            archive.append(le32(0x0403_4B50))
            archive.append(le16(20)) // version needed
            archive.append(le16(0)) // flags
            archive.append(le16(0)) // stored
            archive.append(le16(0)) // time
            archive.append(le16(0x21)) // date: 1980-01-01
            archive.append(le32(crc))
            archive.append(le32(UInt32(data.count)))
            archive.append(le32(UInt32(data.count)))
            archive.append(le16(UInt16(nameBytes.count)))
            archive.append(le16(0)) // extra
            archive.append(nameBytes)
            archive.append(data)

            guard !localOnly.contains(position) else { continue }
            listed += 1
            central.append(le32(0x0201_4B50))
            central.append(le16(0x031E)) // made by: Unix, 3.0
            central.append(le16(20))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0x21))
            central.append(le32(crc))
            central.append(le32(UInt32(data.count)))
            central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0)) // extra
            central.append(le16(0)) // comment
            central.append(le16(0)) // disk
            central.append(le16(0)) // internal attributes
            central.append(le32(UInt32(0o100644) << 16)) // external: regular file
            central.append(le32(offset))
            central.append(nameBytes)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0))
        archive.append(le16(0))
        archive.append(le16(UInt16(listed)))
        archive.append(le16(UInt16(listed)))
        archive.append(le32(UInt32(central.count)))
        archive.append(le32(centralOffset))
        archive.append(le16(0))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fila-ipa-\(UUID().uuidString).ipa")
        try archive.write(to: url)
        return url
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
