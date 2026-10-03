import Darwin
import FilaProtocol
@testable import FilaRemote
import Foundation
import Testing

/// The served folder is the boundary: a device on the network sees what is
/// inside it and nothing else, and writes nowhere else. Symlinks are how that
/// boundary is crossed, so every case here has one inside the share pointing
/// out — at a folder this test can write to, so a write that got through
/// would land rather than fail on permissions and pass by accident.
@Suite("What the share contains", .serialized)
struct ContainmentTests {
    @Test
    func `Nothing is created through a link to a folder outside the share`() async throws {
        let harness = try await Harness()
        let outside = Scratch()
        harness.scratch.file("a.txt", contents: "stays")
        #expect(symlink(outside.root, harness.scratch.path("lib")) == 0)

        let put = try await harness.send("PUT", "/lib/planted", body: Data("x".utf8))
        #expect(put.status == 403)
        let mkcol = try await harness.send("MKCOL", "/lib/made")
        #expect(mkcol.status == 403)
        let deep = try await harness.send("PUT", "/lib/missing/planted", body: Data("x".utf8))
        #expect(deep.status == 403)
        for method in ["MOVE", "COPY"] {
            let reply = try await harness.send(method, "/a.txt", headers: [
                "Destination": "http://127.0.0.1:\(harness.port)/lib/a.txt",
            ])
            #expect(reply.status == 403)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.root).isEmpty)
        #expect(harness.scratch.contents("a.txt") == "stays")
    }

    @Test
    func `A chain of links inside the share cannot reach a file outside it`() async throws {
        let harness = try await Harness()
        let outside = Scratch()
        outside.file("secret.txt", contents: "secret")
        outside.directory("folder")
        // `a` is a link to `b`, which is a link out. A check that follows one
        // link sees `b`, a path inside the share; the kernel follows both.
        #expect(symlink(outside.path("secret.txt"), harness.scratch.path("b")) == 0)
        #expect(symlink("b", harness.scratch.path("a")) == 0)
        #expect(symlink(outside.path("folder"), harness.scratch.path("d")) == 0)
        #expect(symlink("d", harness.scratch.path("c")) == 0)

        let first = try await harness.send("GET", "/a")
        #expect(first.status == 403)
        #expect(!first.text.contains("secret"))
        #expect(try await harness.send("GET", "/b").status == 403)
        #expect(try await harness.send("PROPFIND", "/c", headers: ["Depth": "1"]).status == 403)
        #expect(try await harness.send("PUT", "/c/planted", body: Data("x".utf8)).status == 403)
        #expect(!outside.exists("folder/planted"))
    }

    @Test
    func `Links that stay inside the share still work`() async throws {
        let harness = try await Harness()
        harness.scratch.directory("real")
        harness.scratch.file("real/note.txt", contents: "inside")
        #expect(symlink("real", harness.scratch.path("alias")) == 0)
        #expect(symlink("alias", harness.scratch.path("alias2")) == 0)

        let read = try await harness.send("GET", "/alias2/note.txt")
        #expect(read.status == 200)
        #expect(read.text == "inside")
        let put = try await harness.send("PUT", "/alias2/new.txt", body: Data("made".utf8))
        #expect(put.status == 201)
        #expect(harness.scratch.contents("real/new.txt") == "made")
    }

    @Test
    func `A link that loops is refused rather than followed for ever`() async throws {
        let harness = try await Harness()
        #expect(symlink("loop", harness.scratch.path("loop")) == 0)
        #expect(try await harness.send("GET", "/loop").status == 403)
        #expect(try await harness.send("PUT", "/loop/x", body: Data("x".utf8)).status == 403)
    }

    /// A `PUT` is an edit of the file at that URL, so a link there is written
    /// through — the link stays a link, as the kernel's own `open` would
    /// leave it — and only while the file it names is inside the share.
    @Test
    func `PUT onto a link inside the share updates the file it names and keeps the link`() async throws {
        let harness = try await Harness()
        harness.scratch.directory("real")
        harness.scratch.file("real/note.txt", contents: "old")
        #expect(symlink("real/note.txt", harness.scratch.path("alias.txt")) == 0)

        let put = try await harness.send("PUT", "/alias.txt", body: Data("new".utf8))
        #expect(put.status == 204)
        #expect(harness.scratch.contents("real/note.txt") == "new")
        var status = stat()
        #expect(lstat(harness.scratch.path("alias.txt"), &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFLNK)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.scratch.path("real"))
        #expect(!leftovers.contains { $0.hasPrefix(".fila-tmp-") })
    }

    @Test
    func `PUT onto a link that leaves the share is refused and changes nothing`() async throws {
        let harness = try await Harness()
        let outside = Scratch()
        outside.file("secret.txt", contents: "secret")
        #expect(symlink(outside.path("secret.txt"), harness.scratch.path("out.txt")) == 0)

        let put = try await harness.send("PUT", "/out.txt", body: Data("x".utf8))
        #expect(put.status == 403)
        #expect(outside.contents("secret.txt") == "secret")
        var status = stat()
        #expect(lstat(harness.scratch.path("out.txt"), &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFLNK)
    }

    /// The kernel splits a path on the byte `/`. A name that starts with a
    /// combining mark makes one grapheme with the separator before it, and a
    /// containment check made over `Character`s would see it outside the share.
    @Test
    func `A name that starts with a combining mark is inside the share`() async throws {
        let harness = try await Harness()
        harness.scratch.file("\u{301}accent.txt", contents: "inside")

        let read = try await harness.send("GET", "/%CC%81accent.txt")
        #expect(read.status == 200)
        #expect(read.text == "inside")
    }

    /// Walking up past a missing name is right only when the name is missing.
    /// A link whose own lookup failed for another reason points somewhere
    /// nobody knows, and the request is refused rather than judged by the
    /// link's name.
    @Test
    func `A link whose lookup fails is refused rather than placed by its name`() async throws {
        let service = FailingLookupService()
        let scratch = Scratch()
        let outside = Scratch()
        #expect(symlink(outside.root, scratch.path("lib")) == 0)
        service.failing = scratch.path("lib")

        #expect(await service.resolvedPath(of: scratch.path("lib/planted")) == nil)
        // Missing, plainly: still placed where the kernel would create it.
        #expect(await service.resolvedPath(of: scratch.path("new/planted")) == scratch.path("new/planted"))
    }

    @Test
    func `A URL in the query does not change which file a request acts on`() async throws {
        let harness = try await Harness()
        harness.scratch.file("keep.txt", contents: "keep")
        harness.scratch.file("victim.txt", contents: "victim")

        let removed = try await harness.send("DELETE", "/keep.txt?ref=http://h/victim.txt")
        #expect(removed.status == 204)
        #expect(!harness.scratch.exists("keep.txt"))
        #expect(harness.scratch.contents("victim.txt") == "victim")
    }
}

/// The real filesystem, except that one path's lookup fails the way a dropped
/// link does after its retries.
private final class FailingLookupService: RemoteFileService, @unchecked Sendable {
    let local = LocalService()
    var failing = ""

    func list(_ directory: String) async throws -> [FileNode] {
        try await local.list(directory)
    }

    func details(of path: String) async throws -> FileDetails {
        if path == failing {
            throw FilaFailure(code: .operationFailed, systemError: ECONNRESET, path: path)
        }
        return try await local.details(of: path)
    }

    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32 {
        try await local.open(path, flags: flags, mode: mode)
    }

    func create(_ template: NodeTemplate, at path: String) async throws {
        try await local.create(template, at: path)
    }

    func setAttributes(_ change: AttributeChange, at path: String) async throws {
        try await local.setAttributes(change, at: path)
    }

    func rename(_ source: String, to destination: String, exclusive: Bool) async throws {
        try await local.rename(source, to: destination, exclusive: exclusive)
    }

    func replaceItem(at target: String, withTemporary temporary: String) async throws {
        try await local.replaceItem(at: target, withTemporary: temporary)
    }

    func run(_ job: JobRequest) async throws {
        try await local.run(job)
    }
}

/// A `MOVE` across a mount point inside the share, without needing two
/// volumes: the source's rename reports `EXDEV`, which sends the server down
/// its copy-then-remove path, and the move job does whatever the test says.
private final class CrossVolumeService: RemoteFileService, @unchecked Sendable {
    let local = LocalService()
    var moving = ""
    let moveJob: @Sendable (JobRequest, LocalService) async throws -> Void

    init(moveJob: @escaping @Sendable (JobRequest, LocalService) async throws -> Void) {
        self.moveJob = moveJob
    }

    func list(_ directory: String) async throws -> [FileNode] {
        try await local.list(directory)
    }

    func details(of path: String) async throws -> FileDetails {
        try await local.details(of: path)
    }

    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32 {
        try await local.open(path, flags: flags, mode: mode)
    }

    func create(_ template: NodeTemplate, at path: String) async throws {
        try await local.create(template, at: path)
    }

    func setAttributes(_ change: AttributeChange, at path: String) async throws {
        try await local.setAttributes(change, at: path)
    }

    func rename(_ source: String, to destination: String, exclusive: Bool) async throws {
        if source == moving {
            throw FilaFailure(code: .operationFailed, systemError: EXDEV, path: source)
        }
        try await local.rename(source, to: destination, exclusive: exclusive)
    }

    func replaceItem(at target: String, withTemporary temporary: String) async throws {
        try await local.replaceItem(at: target, withTemporary: temporary)
    }

    func run(_ job: JobRequest) async throws {
        if job.kind == .move {
            try await moveJob(job, local)
        } else {
            try await local.run(job)
        }
    }
}

@Suite("A move across volumes that fails", .serialized)
struct FailedCrossVolumeMoveTests {
    private func stagingLeftovers(_ harness: Harness) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: harness.scratch.root).filter { $0.hasPrefix(".fila-dav-") }
    }

    @Test
    func `One that failed while copying leaves the source and no staging directory`() async throws {
        let service = CrossVolumeService { _, _ in
            throw FilaFailure(code: .operationFailed, systemError: ENOSPC)
        }
        let harness = try await Harness(service: service)
        harness.scratch.file("from.txt", contents: "original")
        service.moving = harness.scratch.path("from.txt")

        let reply = try await harness.send("MOVE", "/from.txt", headers: [
            "Destination": "http://127.0.0.1:\(harness.port)/to.txt",
        ])
        #expect(reply.status == 507)
        #expect(harness.scratch.contents("from.txt") == "original")
        #expect(!harness.scratch.exists("to.txt"))
        #expect(try stagingLeftovers(harness).isEmpty)
        #expect(!harness.server.log.contains { $0.text.contains("Your files are in") })
    }

    @Test
    func `One stopped after copying keeps the copy and says the original may be incomplete`() async throws {
        let service = CrossVolumeService { job, local in
            // The copy landed; the job stopped before the source went.
            try await local.run(JobRequest(kind: .copy, sources: job.sources, destination: job.destination))
            throw FilaFailure(code: .cancelled)
        }
        let harness = try await Harness(service: service)
        harness.scratch.file("from.txt", contents: "original")
        service.moving = harness.scratch.path("from.txt")

        _ = try await harness.send("MOVE", "/from.txt", headers: [
            "Destination": "http://127.0.0.1:\(harness.port)/to.txt",
        ])
        #expect(harness.scratch.contents("from.txt") == "original")
        let staging = try stagingLeftovers(harness)
        #expect(staging.count == 1)
        if let staging = staging.first {
            #expect(harness.scratch.contents(staging + "/from.txt") == "original")
        }
        #expect(harness.server.log.contains { $0.text.contains("may be incomplete") })
    }
}

@Suite("Connection slots", .serialized)
struct ConnectionSlotTests {
    /// A TCP connection that says nothing — what anyone on the network can
    /// open without a password.
    private func silentConnection(to port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
        return descriptor
    }

    @Test
    func `Silent connections cannot lock out a client with the password`() async throws {
        let harness = try await Harness()
        var silent: [Int32] = []
        defer { silent.forEach { close($0) } }
        for _ in 0 ..< WebDAVServer.connectionLimit {
            try silent.append(silentConnection(to: harness.port))
        }
        // Accepted on the server's own loop, so let it catch up.
        try await Task.sleep(nanoseconds: 300_000_000)

        let reply = try await harness.send("OPTIONS", "/")
        #expect(reply.status == 200)
    }
}
