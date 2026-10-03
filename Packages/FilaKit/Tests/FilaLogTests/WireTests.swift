#if canImport(XPC)
    @testable import FilaLog
    @testable import FilaProtocol
    import Foundation
    import Testing
    import XPC

    // There is no longer anywhere off the vphone that runs a real `filad`, so this
    // is the only place the `fetchLog` wire format is exercised at all. Both ends
    // compile the same encoder, so what these check is that the request the app
    // builds is the request the daemon reads, and that the reply survives the trip
    // with its levels, sources and cursors intact.

    @Suite("Log on the wire")
    struct LogWireTests {
        @Test
        func `A poll carries its cursor and the level the daemon should capture at`() {
            let request = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeRequest(since: 4211, level: .verbose, into: request)

            let decoded = FilaLog.Record.decodeRequest(request)
            #expect(decoded.sequence == 4211)
            #expect(decoded.level == .verbose)
        }

        @Test
        func `A poll with no level named leaves the daemon's alone`() {
            // A client that only wants the lines must not be able to silently turn
            // the daemon's capture down as a side effect.
            let request = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(request, FilaWireKey.logCursor, 7)

            let decoded = FilaLog.Record.decodeRequest(request)
            #expect(decoded.sequence == 7)
            #expect(decoded.level == nil)
        }

        @Test
        func `A cursor from a daemon that has since been replaced counts from the start`() {
            // The new `filad` numbers its lines from 1 again. Paging past the
            // old one's last line would hide everything it has said — the
            // lines that explain why it was restarted among them.
            let stale = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeRequest(since: 900, level: .info, instance: "an earlier filad", into: stale)
            #expect(FilaLog.Record.decodeRequest(stale).sequence == 0)

            let current = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeRequest(since: 900, level: .info, instance: FilaLog.instance, into: current)
            #expect(FilaLog.Record.decodeRequest(current).sequence == 900)

            // An app that predates the field pages by the cursor, as it always did.
            let older = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeRequest(since: 900, level: .info, into: older)
            #expect(FilaLog.Record.decodeRequest(older).sequence == 900)
        }

        @Test
        func `A reply names the daemon that wrote it`() {
            let reply = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeReply([], dropped: 0, into: reply)
            #expect(FilaLog.Record.decodeReply(reply).instance == FilaLog.instance)

            // A daemon that predates the field says nothing, and nothing is read.
            let older = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(older, FilaWireKey.logDropped, 3)
            #expect(FilaLog.Record.decodeReply(older).instance == nil)
            #expect(FilaLog.Record.decodeReply(older).dropped == 3)
        }

        @Test
        func `A record that is not a dictionary is skipped, not fatal`() {
            // libxpc kills the process for a dictionary accessor on anything else.
            let reply = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeReply(
                [FilaLog.Record(sequence: 1, time: 1, level: .info, source: .daemon, message: "kept")],
                dropped: 0,
                into: reply,
            )
            let records = xpc_dictionary_get_value(reply, FilaWireKey.logRecords)!
            xpc_array_set_string(records, FilaXPC.arrayAppend, "not a record")

            #expect(FilaLog.Record.decodeReply(reply).records.map(\.message) == ["kept"])
        }

        @Test
        func `Records survive the round trip whole`() {
            let records = [
                FilaLog.Record(sequence: 1, time: 1_756_000_000.25, level: .verbose, source: .daemon, message: "list /"),
                FilaLog.Record(
                    sequence: 2,
                    time: 1_756_000_000.5,
                    level: .error,
                    source: .daemon,
                    message: "unlink /private/var/mobile/Library/Preferences/x.plist failed errno 1 Operation not permitted",
                ),
                FilaLog.Record(sequence: 3, time: 1_756_000_001, level: .warning, source: .daemon, message: "guard /"),
            ]
            let reply = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeReply(records, dropped: 812, into: reply)

            let decoded = FilaLog.Record.decodeReply(reply)
            #expect(decoded.dropped == 812)
            #expect(decoded.records == records)
        }

        @Test
        func `An empty answer is an answer, not a failure`() {
            // The common case once the screen has caught up: nothing new since the
            // cursor, and the poll must not read that as a broken link.
            let reply = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeReply([], dropped: 0, into: reply)

            let decoded = FilaLog.Record.decodeReply(reply)
            #expect(decoded.records.isEmpty)
            #expect(decoded.dropped == 0)
        }

        @Test
        func `A whole ring fits in one message, so a poll is never paged`() {
            // The daemon answers with everything after the cursor in one reply.
            // Worst case is a full ring of the shortest possible frames, which is
            // the most records `FilaProtocol.maximumMessageByteCount` ever has to
            // carry — if that stopped being true the transport would need paging
            // and silently would not have it.
            var ring = FilaLogRing(capacityBytes: FilaLog.daemonCapacityBytes)
            while ring.droppedCount == 0 {
                ring.append(level: .verbose, source: .daemon, message: "")
            }
            let records = ring.records(since: 0)
            let reply = xpc_dictionary_create(nil, nil, 0)
            FilaLog.Record.encodeReply(records, dropped: ring.droppedCount, into: reply)

            // `xpc_copy_description` is not a byte count, so measure what the
            // records themselves cost plus a generous per-entry envelope.
            let envelopePerRecord = 64
            let encoded = records.reduce(0) { $0 + $1.message.utf8.count + envelopePerRecord }
            #expect(encoded < FilaProtocol.maximumMessageByteCount)
            #expect(FilaLog.Record.decodeReply(reply).records.count == records.count)
        }

        @Test
        func `The operation and the reply codes keep the names a log is searched by`() {
            // A log is only greppable if the words are fixed. These are on screen
            // and in files people paste into issues.
            #expect(FilaOperation.fetchLog.rawValue == 16)
            #expect(FilaOperation.allCases.allSatisfy { !$0.name.isEmpty })
            #expect(Set(FilaOperation.allCases.map(\.name)).count == FilaOperation.allCases.count)
            #expect(FilaReplyCode.protectedPath.name == "guard")
            #expect(FilaReplyCode.notFound.name == "missing")
        }

        @Test
        func `The path in a log line is a path, never a value`() {
            // `setAttributes` carries an extended attribute's bytes in the same
            // dictionary the log line's path is read out of. Reading one into a
            // line is the exact mistake the privacy rule exists to prevent, so the
            // helper both ends share is checked here rather than trusted.
            let request = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(request, FilaWireKey.path, "/private/etc/hosts")
            let secret = Array("hunter2".utf8)
            secret.withUnsafeBytes {
                xpc_dictionary_set_data(request, FilaWireKey.attributeValue, $0.baseAddress, $0.count)
            }
            xpc_dictionary_set_string(request, FilaWireKey.attributeName, "user.password")

            #expect(FilaLog.requestPath(request) == "/private/etc/hosts")

            // A move names both ends, because "renamed to what" is the question.
            let move = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(move, FilaWireKey.path, "/a")
            xpc_dictionary_set_string(move, FilaWireKey.destination, "/b")
            #expect(FilaLog.requestPath(move) == "/a → /b")

            #expect(FilaLog.requestPath(xpc_dictionary_create(nil, nil, 0)) == "-")
        }
    }
#endif
