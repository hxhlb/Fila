#if canImport(XPC)
    import FilaClient
    @testable import FilaPrivileged
    @testable import FilaProtocol
    import Foundation
    import Testing
    import XPC

    /// What a dead link takes with it when it goes.
    ///
    /// When `filad` exits, every request still in flight on its connection is
    /// answered with an error, each in its own reply block, and a request from
    /// another thread may build the replacement link between two of them. The
    /// daemon cancels every job a peer started when that peer's connection
    /// ends, so a late reply from the old link that cancelled the new one
    /// would stop a paste the user had just started on it.
    ///
    /// There is no daemon on the Mac, and that is enough here: the Mach
    /// service is not registered, so a connection is built and every request
    /// on it fails the way one to a daemon that just exited does.
    @Suite("Daemon link resets")
    struct DaemonLinkResetTests {
        @Test
        func `A stale link's failure leaves its replacement alone`() throws {
            let service = DaemonFileService(streams: FileEventStreams())
            let stale = try service.activeConnection()
            // The first failing reply on the old link drops it.
            service.invalidate(generation: stale.generation)
            // Another request builds the replacement.
            let replacement = try service.activeConnection()
            #expect(replacement.connection !== stale.connection)
            // The next failing reply on the old link arrives.
            service.invalidate(generation: stale.generation)
            #expect(try service.activeConnection().connection === replacement.connection)
        }

        /// The old link's own end — the invalid event its cancellation
        /// produces — arrives after the replacement may already be running
        /// jobs, and reporting it would end those jobs' rows as lost.
        @Test
        func `Only the newest link's end is reported as a lost link`() throws {
            let service = DaemonFileService(streams: FileEventStreams())
            let stale = try service.activeConnection()
            #expect(service.isNewest(stale.generation))
            service.invalidate(generation: stale.generation)
            // Retired, and nothing built since: its end is still the news.
            #expect(service.isNewest(stale.generation))
            let replacement = try service.activeConnection()
            #expect(!service.isNewest(stale.generation))
            #expect(service.isNewest(replacement.generation))
        }

        /// Its own end is then never reported, so the link a failing reply
        /// retires is reported lost at that moment, before anything can
        /// replace it: the jobs it carried died with it.
        @Test
        func `Retiring a dead link reports it lost before a replacement exists`() throws {
            let service = DaemonFileService(streams: FileEventStreams())
            let losses = LossCount()
            service.onLinkLost = { losses.bump() }
            let stale = try service.activeConnection()
            service.invalidate(generation: stale.generation)
            #expect(losses.value >= 1)
        }

        @Test
        func `A request that fails drops the link it was sent on`() async throws {
            let service = DaemonFileService(streams: FileEventStreams())
            let first = try service.activeConnection()
            await #expect(throws: FilaFailure.self) {
                _ = try await service.hello()
            }
            // Dead for good, so the next request has to build a new one.
            #expect(try service.activeConnection().connection !== first.connection)
        }
    }

    private final class LossCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() {
            lock.lock(); count += 1; lock.unlock()
        }

        var value: Int {
            lock.lock(); defer { lock.unlock() }; return count
        }
    }
#endif
