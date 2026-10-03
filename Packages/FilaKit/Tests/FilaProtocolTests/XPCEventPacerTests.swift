#if canImport(XPC)
    import Dispatch
    @testable import FilaProtocol
    import Foundation
    import Testing
    import XPC

    // A peer that has stopped reading — an app iOS suspended — is the case that
    // matters, and it is one where the barrier never fires. So the transport is
    // replaced by one that records what was handed to libxpc and holds every
    // barrier until the test lets it go.

    private final class StalledPeer: @unchecked Sendable {
        private let lock = NSLock()
        private var sentMessages: [xpc_object_t] = []
        private var barriers: [() -> Void] = []

        var sent: [xpc_object_t] {
            lock.lock()
            defer { lock.unlock() }
            return sentMessages
        }

        var waitingBarriers: Int {
            lock.lock()
            defer { lock.unlock() }
            return barriers.count
        }

        func pacer() -> XPCEventPacer {
            XPCEventPacer(
                send: { [self] message in
                    lock.lock()
                    sentMessages.append(message)
                    lock.unlock()
                },
                barrier: { [self] block in
                    lock.lock()
                    barriers.append(block)
                    lock.unlock()
                },
            )
        }

        /// The peer reads again: everything sent so far has left.
        func drain() {
            lock.lock()
            let pending = barriers
            barriers.removeAll()
            lock.unlock()
            pending.forEach { $0() }
        }
    }

    private func message(_ value: UInt64) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, "n", value)
        return message
    }

    private func values(_ messages: [xpc_object_t]) -> [UInt64] {
        messages.map { xpc_dictionary_get_uint64($0, "n") }
    }

    /// Departures come back through the pacer's own queue; give it a moment.
    private func settle(until condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// `sendInOrder` blocks its caller, as it blocks a search's walk, so it
    /// gets a thread of its own. A detached task would hold one of the few
    /// cooperative threads every other test in the run is waiting on.
    private func onThread(_ body: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { continuation in
                Thread {
                    body()
                    continuation.resume()
                }.start()
            }
        }
    }

    @Suite("Unsolicited messages to a peer that stopped reading", .serialized)
    struct XPCEventPacerTests {
        @Test
        func `Progress to a stalled peer is one message in flight and one waiting, however long it runs`() async {
            let peer = StalledPeer()
            let pacer = peer.pacer()
            // Ten minutes of a copy's progress at ten a second.
            for value in 1 ... 6000 {
                pacer.sendLatest(message(UInt64(value)))
            }
            #expect(values(peer.sent) == [1])

            peer.drain()
            await settle { peer.sent.count == 2 }
            // Only the newest of the five thousand nine hundred and ninety-nine.
            #expect(values(peer.sent) == [1, 6000])
        }

        @Test
        func `Completion is always sent, and nothing superseded follows it`() async {
            let peer = StalledPeer()
            let pacer = peer.pacer()
            pacer.sendLatest(message(1))
            pacer.sendLatest(message(2))
            pacer.finish(message(99))
            #expect(values(peer.sent) == [1, 99])

            peer.drain()
            await settle { peer.waitingBarriers == 0 }
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(values(peer.sent) == [1, 99])
        }

        @Test
        func `A search batch waits for the last message to leave instead of piling up`() async {
            let peer = StalledPeer()
            let pacer = peer.pacer()
            pacer.sendLatest(message(1))

            let delivered = onThread {
                pacer.sendInOrder(message(2)) { false }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            // The walk is paused, not queueing.
            #expect(values(peer.sent) == [1])

            peer.drain()
            await delivered.value
            #expect(values(peer.sent) == [1, 2])
        }

        @Test
        func `A waiting batch lets go when its job is cancelled`() async {
            let peer = StalledPeer()
            let pacer = peer.pacer()
            pacer.sendLatest(message(1))
            let cancelled = Flag()

            let delivered = onThread {
                pacer.sendInOrder(message(2)) { cancelled.isSet }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            cancelled.set()
            await delivered.value
            #expect(values(peer.sent) == [1])
        }

        @Test
        func `A waiting batch polls at its interval, however many messages left before it`() async {
            let peer = StalledPeer()
            let pacer = peer.pacer()
            // A long run of progress to a peer that reads: every departure
            // signals, and nothing is waiting for any of them.
            for value in 1 ... 500 {
                pacer.sendLatest(message(UInt64(value)))
                peer.drain()
                await settle { peer.waitingBarriers == 0 }
            }
            // Then the peer stalls with one message in flight.
            pacer.sendLatest(message(1000))
            let looks = Looks()
            let cancelled = Flag()
            let started = Date()
            let waiting = onThread {
                pacer.sendInOrder(message(2000)) {
                    looks.count()
                    return cancelled.isSet
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            cancelled.set()
            await waiting.value
            // One look per interval for as long as it waited, measured: a
            // loaded machine stretches the sleep above. The 500 signals left
            // over from the progress would otherwise answer the wait at once,
            // 500 times.
            let intervals = Date().timeIntervalSince(started) / 0.1
            #expect(Double(looks.value) <= intervals + 3, "\(looks.value) looks in \(intervals) intervals")
            #expect(looks.value < 500)
        }

        @Test
        func `Over a real connection the messages arrive in order and completion arrives last`() async throws {
            // An anonymous listener in this process, so the barrier is libxpc's
            // own rather than the stand-in above.
            let queue = DispatchQueue(label: "wiki.qaq.fila.tests.pacer")
            let listener = xpc_connection_create(nil, queue)
            let received = Received()
            let serverSide = Received.Connection()
            xpc_connection_set_event_handler(listener) { peer in
                guard xpc_get_type(peer) == FilaXPC.typeConnection else { return }
                xpc_connection_set_event_handler(peer) { _ in }
                xpc_connection_activate(peer)
                serverSide.set(peer)
            }
            xpc_connection_activate(listener)
            let client = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
            xpc_connection_set_event_handler(client) { message in
                guard xpc_get_type(message) == FilaXPC.typeDictionary else { return }
                received.append(xpc_dictionary_get_uint64(message, "n"))
            }
            xpc_connection_activate(client)
            defer {
                xpc_connection_cancel(client)
                xpc_connection_cancel(listener)
            }
            // The listener only hears of the client once it says something.
            xpc_connection_send_message(client, message(0))
            await settle { serverSide.value != nil }
            let connection = try #require(serverSide.value)

            let pacer = XPCEventPacer(connection: connection)
            for value in 1 ... 500 {
                pacer.sendLatest(message(UInt64(value)))
            }
            pacer.sendInOrder(message(1000)) { false }
            pacer.finish(message(9999))

            await settle { received.values.last == 9999 }
            let arrived = received.values
            #expect(arrived.last == 9999)
            #expect(arrived.filter { $0 == 9999 }.count == 1)
            #expect(arrived.contains(1000))
            // In the order they were handed over, and nothing after completion.
            #expect(arrived.dropLast().allSatisfy { $0 < 9999 })
            #expect(arrived == arrived.sorted())
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private final class Looks: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func count() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt64] = []

        var values: [UInt64] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: UInt64) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        final class Connection: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: xpc_connection_t?

            var value: xpc_connection_t? {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }

            func set(_ connection: xpc_connection_t) {
                lock.lock()
                stored = connection
                lock.unlock()
            }
        }
    }
#endif
