import FilaClient
import FilaLog
import FilaProtocol
import Foundation
import XPC

/// The app's side of the link to `filad`: every operation as one XPC message.
///
/// Looking the Mach service up is what starts the daemon: it is on-demand, so
/// there is nothing to install or launch by hand. Every call here is one XPC
/// message with an asynchronous reply — never the synchronous variant, which
/// wedges its queue forever when a reply does not come and, because the app
/// deliberately never shows a connection failure, produces an eternal spinner
/// with nothing to read anywhere.
///
/// The class is a reference type because it owns a connection; it is safe from
/// any thread because everything it mutates is behind `stateLock`.
final class DaemonFileService: LocalFileAccess, @unchecked Sendable {
    private let queue = DispatchQueue(label: "wiki.qaq.fila.client", qos: .userInitiated)
    private let stateLock = NSLock()
    private var connection: xpc_connection_t?
    /// Counts the links built, so a reply can name the one it was sent on
    /// without holding it. See `invalidate(generation:)`.
    private var connectionGeneration: UInt64 = 0
    /// `FilaLog.instance` of the daemon that answered the last log poll. The
    /// log screen holds one cursor, so this is the daemon that cursor belongs to.
    private var logInstance: String?

    /// Where unsolicited messages go. Owned by `DaemonLink`, because the app
    /// starts reading the streams before either service has been chosen.
    private let streams: FileEventStreams

    var jobEvents: AsyncStream<JobUpdate> {
        streams.jobEvents
    }

    var searchResults: AsyncStream<SearchUpdate> {
        streams.searchResults
    }

    /// Called when the connection goes away. Set once, before the first
    /// request; it fires on the connection's own queue and may fire more than
    /// once for a single disconnection, so whatever it does must be idempotent.
    var onLinkLost: (@Sendable () -> Void)?

    init(streams: FileEventStreams) {
        self.streams = streams
    }

    // MARK: - Requests

    func hello() async throws -> LocalHello {
        let reply = try await send(.hello) { request in
            xpc_dictionary_set_uint64(request, FilaWireKey.version, FilaProtocol.version)
        }
        guard let root = xpc_dictionary_get_string(reply, FilaWireKey.installRoot) else {
            throw FilaFailure(code: .operationFailed)
        }
        return LocalHello(
            protocolVersion: xpc_dictionary_get_uint64(reply, FilaWireKey.version),
            backend: .daemon(installRoot: String(cString: root)),
        )
    }

    func closeDirectory(cursor: UInt64) async throws {
        _ = try await send(.closeDirectory) { request in
            xpc_dictionary_set_uint64(request, FilaWireKey.cursor, cursor)
        }
    }

    func list(directory: String, cursor: UInt64) async throws -> DirectoryPage {
        let reply = try await send(.listDirectory) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, directory)
            xpc_dictionary_set_uint64(request, FilaWireKey.cursor, cursor)
        }
        var entries: [FileNode] = []
        if let array = xpc_dictionary_get_array(reply, FilaWireKey.entries) {
            entries.reserveCapacity(xpc_array_get_count(array))
            for index in 0 ..< xpc_array_get_count(array) {
                guard let node = FileNode(decoding: xpc_array_get_value(array, index)) else { continue }
                entries.append(node)
            }
        }
        return DirectoryPage(entries: entries, cursor: xpc_dictionary_get_uint64(reply, FilaWireKey.cursor))
    }

    func details(of path: String) async throws -> FileDetails {
        let reply = try await send(.statPath) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, path)
        }
        guard let value = xpc_dictionary_get_value(reply, FilaWireKey.details),
              let details = FileDetails(decoding: value)
        else {
            throw FilaFailure(code: .operationFailed, path: path)
        }
        return details
    }

    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32 {
        let reply = try await send(.openPath) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, path)
            xpc_dictionary_set_int64(request, FilaWireKey.openFlags, Int64(flags))
            xpc_dictionary_set_uint64(request, FilaWireKey.mode, UInt64(mode))
        }
        let descriptor = xpc_dictionary_dup_fd(reply, FilaWireKey.descriptor)
        guard descriptor >= 0 else { throw FilaFailure(code: .operationFailed, path: path) }
        return descriptor
    }

    func create(_ template: NodeTemplate, at path: String, mode: mode_t?) async throws {
        _ = try await send(.createNode) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, path)
            template.encode(into: request)
            if let mode {
                xpc_dictionary_set_uint64(request, FilaWireKey.mode, UInt64(mode))
            }
        }
    }

    func rename(_ source: String, to destination: String, exclusive: Bool, overrideGuard: Bool) async throws {
        _ = try await send(.rename) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, source)
            xpc_dictionary_set_string(request, FilaWireKey.destination, destination)
            xpc_dictionary_set_bool(request, FilaWireKey.exclusive, exclusive)
            xpc_dictionary_set_bool(request, FilaWireKey.overrideGuard, overrideGuard)
        }
    }

    func remove(_ path: String, directory: Bool, overrideGuard: Bool) async throws {
        _ = try await send(.removeNode) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, path)
            xpc_dictionary_set_bool(request, FilaWireKey.removeDirectory, directory)
            xpc_dictionary_set_bool(request, FilaWireKey.overrideGuard, overrideGuard)
        }
    }

    func setAttributes(_ change: AttributeChange, at path: String) async throws -> AttributeOutcome {
        let reply = try await send(.setAttributes) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, path)
            xpc_dictionary_set_value(request, FilaWireKey.attributes, change.encoded())
        }
        let unchanged = xpc_dictionary_get_uint64(reply, FilaWireKey.unchangedSharedFiles)
        return AttributeOutcome(unchangedSharedFiles: Int(clamping: unchanged))
    }

    func replaceItem(at target: String, withTemporary temporary: String) async throws {
        _ = try await send(.replaceItem) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, temporary)
            xpc_dictionary_set_string(request, FilaWireKey.destination, target)
        }
    }

    func mountPoints() async throws -> [MountPoint] {
        let reply = try await send(.mountPoints) { _ in }
        guard let values = xpc_dictionary_get_value(reply, FilaWireKey.mounts),
              xpc_get_type(values) == FilaXPC.typeArray else { throw FilaFailure(code: .operationFailed) }
        return try (0 ..< xpc_array_get_count(values)).map { index in
            guard let mount = MountPoint(decoding: xpc_array_get_value(values, index)) else {
                throw FilaFailure(code: .operationFailed)
            }
            return mount
        }
    }

    func volumeInfo(for path: String) async throws -> VolumeInfo {
        let reply = try await send(.volumeInfo) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, path)
        }
        guard let value = xpc_dictionary_get_value(reply, FilaWireKey.volume),
              let info = VolumeInfo(decoding: value)
        else {
            throw FilaFailure(code: .operationFailed, path: path)
        }
        return info
    }

    func extendedAttribute(_ name: String, at path: String) async throws -> Data {
        let reply = try await send(.readExtendedAttribute) { request in
            xpc_dictionary_set_string(request, FilaWireKey.path, path)
            xpc_dictionary_set_string(request, FilaWireKey.attributeName, name)
        }
        // A zero-length attribute is a real and common thing — a marker xattr
        // carries no value — and `xpc_dictionary_get_data` hands back nil for
        // one, indistinguishable from a key that was never set. The key's
        // presence is what separates them, so ask about that first.
        guard xpc_dictionary_get_value(reply, FilaWireKey.attributeValue) != nil else {
            throw FilaFailure(code: .operationFailed, path: path)
        }
        var length = 0
        guard let bytes = xpc_dictionary_get_data(reply, FilaWireKey.attributeValue, &length) else {
            return Data()
        }
        return Data(bytes: bytes, count: length)
    }

    func startJob(_ job: JobRequest) async throws -> UInt64 {
        let reply = try await send(.startJob) { request in
            job.encode(into: request)
        }
        return xpc_dictionary_get_uint64(reply, FilaWireKey.jobIdentifier)
    }

    func cancelJob(_ identifier: UInt64) async throws {
        _ = try await send(.cancelJob) { request in
            xpc_dictionary_set_uint64(request, FilaWireKey.jobIdentifier, identifier)
        }
    }

    func fetchLog(
        since sequence: UInt64,
        level: FilaLog.Level,
    ) async throws -> (records: [FilaLog.Record], dropped: UInt64) {
        let instance = currentLogInstance()
        // The daemon the cursor was read from travels with it. One that
        // launchd has since replaced counts its lines from 1 again, and only
        // the daemon can tell its own instance from another, so it is the one
        // that decides to answer from the start.
        let reply = try await send(.fetchLog) { request in
            FilaLog.Record.encodeRequest(since: sequence, level: level, instance: instance, into: request)
        }
        let answer = FilaLog.Record.decodeReply(reply)
        // The caller's next cursor is the last record's sequence, which belongs
        // to the daemon that answered — or, when nothing came back, still the
        // cursor it sent, which belongs to the instance it was sent with.
        if !answer.records.isEmpty || instance == nil {
            noteLogInstance(answer.instance)
        }
        return (answer.records, answer.dropped)
    }

    private func currentLogInstance() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return logInstance
    }

    private func noteLogInstance(_ instance: String?) {
        stateLock.lock()
        logInstance = instance
        stateLock.unlock()
    }

    /// Drop whatever link is current — for the end of the process. A request
    /// whose reply reports its link dead drops that link alone, through
    /// `invalidate(generation:)`; this one would also take a replacement
    /// another request had just built.
    func invalidate() {
        stateLock.lock()
        let existing = connection
        connection = nil
        stateLock.unlock()
        guard let existing else { return }
        xpc_connection_cancel(existing)
    }

    /// Drop the link `generation` names, and only that one.
    ///
    /// For a reply that came back as a connection error. Every request still
    /// in flight on a link that died gets one of those, each in its own block,
    /// and a request from another thread may have built the replacement link
    /// in between. Cancelling whatever is current would cancel that one — and
    /// the daemon cancels every job a peer started when its connection goes,
    /// so a paste started on the new link would stop part-way.
    ///
    /// The link this retires is reported lost here, while nothing has
    /// replaced it yet: the reply proves it dead, so its jobs died with it,
    /// and the event its own cancellation produces may arrive after a
    /// replacement exists, when `isNewest` no longer lets it be reported.
    func invalidate(generation stale: UInt64) {
        stateLock.lock()
        let existing = connectionGeneration == stale ? connection : nil
        stateLock.unlock()
        guard let existing else { return }
        // Reported before the link is cleared: no replacement can be built
        // until the loss is on its way.
        onLinkLost?()
        stateLock.lock()
        let retires = connectionGeneration == stale && connection === existing
        if retires {
            connection = nil
        }
        stateLock.unlock()
        guard retires else { return }
        xpc_connection_cancel(existing)
    }

    /// Whether `generation` is the newest link built. Only that link's end
    /// is news: an older one was retired by `invalidate`, which reported it
    /// then, and its late events must not end jobs running on its successor.
    func isNewest(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connectionGeneration == generation
    }

    // MARK: - Transport

    /// Not private: `DaemonLink` sends the two terminal operations straight
    /// through here rather than through `LocalFileAccess`. A terminal is the one
    /// thing the local backend cannot answer — a session spawned in the app would give
    /// a shell running as `mobile`, which is not the feature — so putting it on
    /// the protocol would mean a second implementation whose only job is to
    /// refuse.
    func send(
        _ operation: FilaOperation,
        fill: (xpc_object_t) -> Void,
    ) async throws -> xpc_object_t {
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(request, FilaWireKey.operation, operation.rawValue)
        fill(request)

        // Every round trip the app makes, in one place — which is the only
        // reason "verbose logs every XPC call" costs eight lines rather than
        // one at each of forty call sites. `fetchLog` itself is skipped: the
        // log screen polls once a second and a log of its own polling is a log
        // of nothing else.
        let logging = operation != .fetchLog
        if logging {
            FilaLog.verbose("→ \(operation.name) \(FilaLog.requestPath(request))")
        }

        let (connection, generation) = try activeConnection()
        let reply: xpc_object_t = try await withCheckedThrowingContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, request, queue) { reply in
                if xpc_get_type(reply) == FilaXPC.typeDictionary {
                    continuation.resume(returning: reply)
                } else {
                    // A connection interrupted or invalid error. The daemon is
                    // on-demand and exits when idle, so this is a normal thing
                    // to see; the next call reconnects.
                    // The one failure the daemon has no line for, because by
                    // definition it never heard the request. Not gated on
                    // verbose for that reason; it is rare, since the daemon
                    // only goes away after an idle gap.
                    FilaLog.info("link reset during \(operation.name)")
                    self.invalidate(generation: generation)
                    continuation.resume(throwing: FilaFailure(code: .operationFailed, systemError: ECONNRESET))
                }
            }
        }
        if let failure = FilaFailure.decode(reply) {
            // The daemon logged this one with its `errno`; this is the app's
            // own entry on the same timeline, so a verbose trace does not stop
            // dead at the request.
            if logging {
                FilaLog.verbose("✗ \(operation.name) \(failure.code.name)")
            }
            throw failure
        }
        if logging {
            FilaLog.verbose("← \(operation.name) ok")
        }
        return reply
    }

    /// The link, and which one it is: a reply that reports it dead names it
    /// by `generation`. Internal rather than private for the tests, which
    /// hold one link while another replaces it.
    func activeConnection() throws -> (connection: xpc_connection_t, generation: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let connection {
            return (connection, connectionGeneration)
        }
        guard let created = FilaProtocol.serviceName.withCString({
            filaCreateMachServiceConnection($0, queue, FilaXPCFlag.client)
        }) else {
            throw FilaFailure(code: .operationFailed, systemError: ENOENT)
        }
        let generation = connectionGeneration &+ 1
        xpc_connection_set_event_handler(created) { [weak self] message in
            guard let self else { return }
            if let update = JobEvent.decode(message) {
                streams.yield(JobUpdate(identifier: update.jobIdentifier, event: update.event))
            } else if let result = SearchBatch.decode(message) {
                streams.yield(SearchUpdate(identifier: result.jobIdentifier, batch: result.batch))
            } else if message === FilaXPC.errorConnectionInterrupted
                || message === FilaXPC.errorConnectionInvalid
            {
                // Not a delivery problem to retry. The daemon cancels every job
                // a peer started when that peer disconnects, so by the time
                // this fires those jobs are already over and nothing will ever
                // arrive on `events` to say so. Without telling somebody, a
                // copy that died with the connection sits on screen at 40%
                // forever and anything awaiting it waits forever with it.
                // Only the newest link's, though: a retired one was reported
                // when it was retired, and its own invalid event may arrive
                // after the replacement has jobs of its own.
                if isNewest(generation) {
                    onLinkLost?()
                }
            }
        }
        xpc_connection_activate(created)
        connection = created
        connectionGeneration = generation
        return (created, generation)
    }

    deinit {
        if let connection {
            xpc_connection_cancel(connection)
        }
    }
}
