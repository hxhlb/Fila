import Darwin
import FilaBackendKit
@testable import FilaSMB
import Foundation
import SMBClient
import Testing

/// The vendored client against a loopback listener that answers whatever a
/// test tells it to: what a broken or hostile server sends, and what a
/// Windows volume root answers, without either. Nothing here logs in: the
/// requests under test go on the wire as they are and their replies are
/// parsed the same way on an authenticated session.
@Suite("SMB client against a scripted server")
struct SMBClientHardeningTests {
    // MARK: - Replies too short or pointing outside themselves

    @Test
    func `A reply too short for its header fails the request, not the process`() async throws {
        let server = try ScriptedSMBServer { _ in Data(count: 10) }
        let client = server.client()
        defer { client.session.disconnect() }
        await expectMalformed { _ = try await client.session.echo() }
    }

    @Test
    func `An error reply too short for its body fails the request, not the process`() async throws {
        let server = try ScriptedSMBServer { _ in
            ScriptedSMBServer.header(status: 0xC000_0022, command: 0x0D) + Data(count: 2)
        }
        let client = server.client()
        defer { client.session.disconnect() }
        await expectMalformed { _ = try await client.session.echo() }
    }

    @Test
    func `A success reply with the smallest body any response has is accepted`() async throws {
        // SET_INFO answers StructureSize 2: 66 bytes in all.
        let server = try ScriptedSMBServer { _ in
            ScriptedSMBServer.header(status: 0, command: 0x11) + Data([2, 0])
        }
        let connection = Connection(host: "127.0.0.1", port: server.port)
        defer { connection.disconnect() }
        let reply = try await connection.send(ScriptedSMBServer.header(status: 0, command: 0x11))
        #expect(reply.count == 66)
    }

    @Test
    func `A success reply with a header and no body is refused`() async throws {
        let server = try ScriptedSMBServer { _ in ScriptedSMBServer.header(status: 0, command: 0x11) }
        let connection = Connection(host: "127.0.0.1", port: server.port)
        defer { connection.disconnect() }
        await expectMalformed { _ = try await connection.send(ScriptedSMBServer.header(status: 0, command: 0x11)) }
    }

    @Test
    func `A compound answered with fewer replies than requests is refused`() async throws {
        // Create and close sent together, one create reply back.
        let server = try ScriptedSMBServer { _ in
            ScriptedSMBServer.header(status: 0, command: 0x05) + ScriptedSMBServer.createBody()
        }
        let client = server.client()
        defer { client.session.disconnect() }
        await expectMalformed { _ = try await client.session.nodeStat(path: "a") }
    }

    @Test
    func `A compound reply whose next one starts past the end is refused`() async throws {
        let server = try ScriptedSMBServer { _ in
            ScriptedSMBServer.header(status: 0, command: 0x05, nextCommand: 4096) + ScriptedSMBServer.createBody()
        }
        let client = server.client()
        defer { client.session.disconnect() }
        await expectMalformed { _ = try await client.session.nodeStat(path: "a") }
    }

    @Test(arguments: [
        // The output buffer runs past the reply.
        ScriptedSMBServer.page(offset: 72, length: 4096, buffer: Data()),
        // The buffer starts past the reply.
        ScriptedSMBServer.page(offset: 9000, length: 0, buffer: Data()),
        // The entry's name runs past the buffer.
        ScriptedSMBServer.page(buffer: ScriptedSMBServer.entry("x", next: 0, nameLength: 4000)),
        // The next entry starts past the buffer.
        ScriptedSMBServer.page(buffer: ScriptedSMBServer.entry("x", next: 0x10_0000)),
        // The next entry starts exactly at the end of the buffer.
        ScriptedSMBServer.page(buffer: ScriptedSMBServer.entry("x", next: 72)),
        // Shorter than one entry's fixed part.
        ScriptedSMBServer.page(buffer: Data(count: 20)),
    ])
    func `A directory page whose offsets point outside it is refused`(reply: Data) async throws {
        let server = try ScriptedSMBServer { _ in reply }
        let client = server.client()
        defer { client.session.disconnect() }
        await expectMalformed {
            _ = try await client.session.queryDirectoryPage(fileId: Data(count: 16), restart: true)
        }
    }

    // MARK: - Pages

    @Test
    func `A session with no negotiated transact size still asks for a page`() async throws {
        // Never negotiated, so MaxTransactSize is 0, as a server that
        // answered 0 leaves it. The page asks for the protocol's minimum.
        let requests = RequestLog()
        let server = try ScriptedSMBServer { request in
            requests.append(request)
            return ScriptedSMBServer.page(buffer: Data())
        }
        let client = server.client()
        defer { client.session.disconnect() }
        #expect(client.session.maxTransactSize == 0)
        _ = try await client.session.queryDirectoryPage(fileId: Data(count: 16), restart: true)
        let request = try #require(requests.first)
        // OutputBufferLength: header, StructureSize, class, flags, index,
        // FileId, name offset and length.
        let length = request[request.startIndex + 92 ..< request.startIndex + 96].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << (8 * $1.offset)
        }
        #expect(length == 65_536)
    }

    @Test
    func `A well-formed page lists every entry and promises more`() async throws {
        let first = ScriptedSMBServer.entry("first", next: 80)
        let second = ScriptedSMBServer.entry("日本語", next: 0, attributes: 0x10)
        let server = try ScriptedSMBServer { _ in ScriptedSMBServer.page(buffer: first + second) }
        let client = server.client()
        defer { client.session.disconnect() }
        let page = try await client.session.queryDirectoryPage(fileId: Data(count: 16), restart: true)
        #expect(page.files.map(\.fileName) == ["first", "日本語"])
        #expect(page.files.map { $0.fileAttributes.contains(.directory) } == [false, true])
        #expect(page.hasMore)
    }

    @Test
    func `An empty volume root answering NO_SUCH_FILE lists as empty`() async throws {
        let server = try ScriptedSMBServer { _ in ScriptedSMBServer.error(status: 0xC000_000F, command: 0x0E) }
        let client = server.client()
        defer { client.session.disconnect() }
        let page = try await client.session.queryDirectoryPage(fileId: Data(count: 16), restart: true)
        #expect(page.files.isEmpty)
        #expect(!page.hasMore)
    }

    @Test
    func `NO_SUCH_FILE after the first page is still the server's refusal`() async throws {
        let server = try ScriptedSMBServer { _ in ScriptedSMBServer.error(status: 0xC000_000F, command: 0x0E) }
        let client = server.client()
        defer { client.session.disconnect() }
        await #expect(throws: ErrorResponse.self) {
            _ = try await client.session.queryDirectoryPage(fileId: Data(count: 16), restart: false)
        }
    }

    @Test
    func `A success page with no entries ends the listing`() async throws {
        let server = try ScriptedSMBServer { _ in ScriptedSMBServer.page(buffer: Data()) }
        let client = server.client()
        defer { client.session.disconnect() }
        let page = try await client.session.queryDirectoryPage(fileId: Data(count: 16), restart: false)
        #expect(page.files.isEmpty)
        #expect(!page.hasMore, "the same question would be asked for ever")
    }

    // MARK: - What goes on the wire

    @Test
    func `A rename sends its new name as given and opens a link as itself`() async throws {
        let requests = RequestLog()
        let server = try ScriptedSMBServer { request in
            requests.append(request)
            return ScriptedSMBServer.error(status: 0xC000_0022, command: 0x05)
        }
        let client = server.client()
        defer { client.session.disconnect() }
        // Decomposed: e and a combining acute accent.
        let decomposed = "caf\u{65}\u{301}"
        _ = try? await client.session.rename(from: "link", to: decomposed, replaceIfExists: false)
        let request = try #require(requests.first)
        #expect(request.range(of: decomposed.data(using: .utf16LittleEndian)!) != nil)
        #expect(request.range(of: "caf\u{e9}".data(using: .utf16LittleEndian)!) == nil)
        #expect(ScriptedSMBServer.createOptions(of: request) & 0x0020_0000 != 0)
    }

    @Test
    func `A node's details open a reparse point as itself`() async throws {
        let requests = RequestLog()
        let server = try ScriptedSMBServer { request in
            requests.append(request)
            return ScriptedSMBServer.error(status: 0xC000_0034, command: 0x05)
        }
        let client = server.client()
        defer { client.session.disconnect() }
        _ = try? await client.session.nodeStat(path: "junction")
        let request = try #require(requests.first)
        #expect(ScriptedSMBServer.createOptions(of: request) & 0x0020_0000 != 0)
    }

    @Test
    func `A reparse point's tag is read from the node itself`() async throws {
        let requests = RequestLog()
        let server = try ScriptedSMBServer { request in
            requests.append(request)
            // IO_REPARSE_TAG_DEDUP on a file.
            return ScriptedSMBServer.attributeTagCompound(attributes: 0x0420, tag: 0x8000_0013)
        }
        let client = server.client()
        defer { client.session.disconnect() }
        #expect(try await client.session.reparseTag(path: "deduplicated") == 0x8000_0013)
        let request = try #require(requests.first)
        #expect(ScriptedSMBServer.createOptions(of: request) & 0x0020_0000 != 0)
    }

    @Test
    func `An attribute tag reply too short to hold the tag is refused`() async throws {
        let server = try ScriptedSMBServer { _ in ScriptedSMBServer.attributeTagCompound(attributes: 0x0420, tag: nil) }
        let client = server.client()
        defer { client.session.disconnect() }
        await expectMalformed { _ = try await client.session.reparseTag(path: "x") }
    }

    @Test
    func `An attribute tag reply that claims more than it holds is refused, not trapped`() async throws {
        // The CLOSE reply follows in the same message; the claimed buffer
        // must not be read on into it, or past the end of the message.
        let server = try ScriptedSMBServer { _ in
            ScriptedSMBServer.attributeTagCompound(attributes: 0x0420, tag: 0xA000_000C, claimedLength: 4096)
        }
        let client = server.client()
        defer { client.session.disconnect() }
        await expectMalformed { _ = try await client.session.reparseTag(path: "x") }
    }

    @Test(arguments: [
        // No tag asked for, as in a listing: taken for a link.
        (FileAttributes.reparsePoint.rawValue, UInt32?.none, FileEntry.Kind.symbolicLink(resolved: .file)),
        // IO_REPARSE_TAG_SYMLINK.
        (FileAttributes.reparsePoint.rawValue, 0xA000_000C, .symbolicLink(resolved: .file)),
        // IO_REPARSE_TAG_MOUNT_POINT: a junction.
        (FileAttributes([.reparsePoint, .directory]).rawValue, 0xA000_0003, .symbolicLink(resolved: .directory)),
        // IO_REPARSE_TAG_DEDUP: a deduplicated file is the file.
        (FileAttributes.reparsePoint.rawValue, 0x8000_0013, .file),
        // IO_REPARSE_TAG_CLOUD_6 on a folder: a placeholder is the folder.
        (FileAttributes([.reparsePoint, .directory]).rawValue, 0x9000_601A, .directory),
        (FileAttributes.directory.rawValue, 0, .directory),
    ] as [(UInt32, UInt32?, FileEntry.Kind)])
    func `Only a name-surrogate reparse point is a link`(attributes: UInt32, tag: UInt32?, kind: FileEntry.Kind) {
        #expect(SMBEntry.kind(FileAttributes(rawValue: attributes), reparseTag: tag) == kind)
    }

    // MARK: - Publication

    @Test
    func `A sent request that got no readable answer has an unknown outcome`() {
        // Publication reports `disconnected` as "may have been published"
        // and keeps the temporary; `connectionFailed` would discard it.
        #expect(SMBFileService.unlessAnswered(ConnectionError.malformedResponse) as? SMBError == .disconnected)
        #expect(SMBFileService.unlessAnswered(POSIXError(.ECONNRESET)) as? SMBError == .disconnected)
        let refusal = ErrorResponse(data: ScriptedSMBServer.error(status: 0xC000_0035, command: 0x05))
        #expect(SMBFileService.unlessAnswered(refusal) is ErrorResponse)
    }

    // MARK: - Setup

    @Test(arguments: [0, 70000, -1])
    func `Listing shares on a port no server can have is refused, not trapped`(port: Int) async {
        let profile = SMBProfile(name: "Bad", host: "127.0.0.1", port: port, share: "s")
        await #expect(throws: SMBError.self) {
            _ = try await SMBShares.list(profile: profile, password: nil, timeout: 1)
        }
    }

    // MARK: - Cancellation

    private func connection(grace: TimeInterval) -> SMBConnection {
        SMBConnection(
            configuration: .init(host: "127.0.0.1", port: 445, share: "s"),
            cancellationGrace: grace,
        )
    }

    @Test
    func `A cancelled request that answers within the grace returns its answer`() async throws {
        let connection = connection(grace: 5)
        let client = SMBClient(host: "127.0.0.1", port: 9)
        let started = Flag()
        let task = Task {
            try await connection.run("probe", path: nil, timeout: 30, on: client) {
                started.set()
                await Self.uncancellableWait(0.3)
                return 7
            }
        }
        try await started.wait()
        task.cancel()
        #expect(try await task.value == 7)
    }

    @Test
    func `A cancelled request still unanswered after the grace is cancelled`() async throws {
        let connection = connection(grace: 0.1)
        let client = SMBClient(host: "127.0.0.1", port: 9)
        let started = Flag()
        let task = Task {
            try await connection.run("probe", path: nil, timeout: 30, on: client) {
                started.set()
                await Self.uncancellableWait(1)
                return 7
            }
        }
        try await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func `A request whose caller was cancelled first is never sent`() async throws {
        let connection = connection(grace: 5)
        let client = SMBClient(host: "127.0.0.1", port: 9)
        let started = Flag()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await connection.run("probe", path: nil, timeout: 30, on: client) {
                started.set()
                return 7
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!started.isSet)
    }

    /// What the vendor's awaits are like: a wait that does not end early
    /// for a cancelled task.
    private static func uncancellableWait(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    private func expectMalformed(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("a malformed reply was accepted")
        } catch let error as ConnectionError {
            #expect(error == .malformedResponse)
        } catch {
            Issue.record("got \(error)")
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    struct Timeout: Error {}

    func wait(seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !isSet {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Data] = []

    func append(_ request: Data) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }

    var first: Data? {
        lock.lock(); defer { lock.unlock() }
        return requests.first
    }
}

/// A loopback TCP listener that reads SMB2 requests in their DirectTCP
/// frames and answers each with what `reply` makes of it, framed the same
/// way. One connection at a time; it stops when the client disconnects.
final class ScriptedSMBServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32

    init(reply: @escaping @Sendable (Data) -> Data) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 4) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        self.listener = listener
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread {
            Self.serve(listener, reply)
        }
    }

    deinit {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    func client() -> SMBClient {
        SMBClient(host: "127.0.0.1", port: port)
    }

    private static func serve(_ listener: Int32, _ reply: (Data) -> Data) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var one: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            while let prefix = read(connection, count: 4) {
                let length = Int(prefix[1]) << 16 | Int(prefix[2]) << 8 | Int(prefix[3])
                guard let request = read(connection, count: length) else { break }
                let answer = reply(request)
                let size = answer.count
                write(Data([0, UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]) + answer, to: connection)
            }
            Darwin.close(connection)
        }
    }

    private static func read(_ descriptor: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let result = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + got, count - got) }
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else { return nil }
            got += result
        }
        return data
    }

    private static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else { return }
                sent += result
            }
        }
    }

    // MARK: - Messages

    static func header(status: UInt32, command: UInt16, nextCommand: UInt32 = 0) -> Data {
        var data = Data()
        data += le(0x424D_53FE as UInt32)
        data += le(64 as UInt16)
        data += le(1 as UInt16)
        data += le(status)
        data += le(command)
        data += le(1 as UInt16)
        data += le(1 as UInt32)
        data += le(nextCommand)
        data += le(0 as UInt64)
        data += le(0 as UInt32)
        data += le(0 as UInt32)
        data += le(0 as UInt64)
        data += Data(count: 16)
        return data
    }

    /// An ERROR response: StructureSize 9 and one byte of error data.
    static func error(status: UInt32, command: UInt16) -> Data {
        header(status: status, command: command) + le(9 as UInt16) + Data(count: 2) + le(0 as UInt32) + Data(count: 1)
    }

    /// A CREATE response body with no create contexts.
    static func createBody() -> Data {
        le(89 as UInt16) + Data(count: 2) + le(1 as UInt32) + Data(count: 48) + le(0x80 as UInt32)
            + Data(count: 4) + Data(count: 16) + le(0 as UInt32) + le(0 as UInt32)
    }

    /// The CREATE, QUERY_INFO of FILE_ATTRIBUTE_TAG_INFORMATION and CLOSE
    /// replies to `reparseTag`, compounded. Without a `tag`, the info
    /// carries the attributes alone. `claimedLength` is the OutputBufferLength
    /// the server states, when it is not the truth.
    static func attributeTagCompound(attributes: UInt32, tag: UInt32?, claimedLength: UInt32? = nil) -> Data {
        let create = header(status: 0, command: 0x05, nextCommand: 152) + createBody()
        let info = le(attributes) + (tag.map { le($0) } ?? Data())
        var body = le(9 as UInt16) + le(72 as UInt16) + le(claimedLength ?? UInt32(info.count)) + info
        body += Data(count: (8 - body.count % 8) % 8)
        let query = header(status: 0, command: 0x10, nextCommand: UInt32(64 + body.count)) + body
        let close = header(status: 0, command: 0x06) + le(60 as UInt16) + Data(count: 58)
        return create + query + close
    }

    /// A QUERY_DIRECTORY success response around `buffer`, its offset and
    /// length as given or as they should be.
    static func page(offset: UInt16 = 72, length: UInt32? = nil, buffer: Data) -> Data {
        header(status: 0, command: 0x0E) + le(9 as UInt16) + le(offset) + le(length ?? UInt32(buffer.count)) + buffer
    }

    /// One FILE_DIRECTORY_INFORMATION entry, padded to eight bytes.
    static func entry(_ name: String, next: UInt32, attributes: UInt32 = 0x80, nameLength: UInt32? = nil) -> Data {
        let encoded = name.data(using: .utf16LittleEndian)!
        var data = le(next) + le(0 as UInt32) + Data(count: 48) + le(attributes)
            + le(nameLength ?? UInt32(encoded.count)) + encoded
        data += Data(count: (8 - data.count % 8) % 8)
        return data
    }

    /// The CreateOptions of the CREATE request that starts `request`.
    static func createOptions(of request: Data) -> UInt32 {
        request[request.startIndex + 104 ..< request.startIndex + 108].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << (8 * $1.offset)
        }
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
