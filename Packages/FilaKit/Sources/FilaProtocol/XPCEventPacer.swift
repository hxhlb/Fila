#if canImport(XPC)
    import Dispatch
    import XPC

    /// One job's unsolicited messages to its peer, with never more than one of
    /// them waiting inside this process.
    ///
    /// `xpc_connection_send_message` does not wait for anything. When the peer
    /// stops reading — and iOS suspends Fila a few seconds after it leaves the
    /// screen — the kernel queue fills and libxpc keeps every further message in
    /// the sender's memory until the peer reads again: about half a kilobyte a
    /// message, measured. A copy reports ten times a second, so a job left
    /// running behind a suspended app would grow `filad` past launchd's 6 MB
    /// jetsam cap in about ten minutes, and the kill would land mid-`copyfile`.
    ///
    /// So a message is handed to libxpc only once the previous one has left
    /// this process, which `xpc_connection_send_barrier` reports. Until then:
    ///
    /// - **progress** is superseded rather than queued — the next one says
    ///   everything the last one did, so only the newest is kept;
    /// - **a search batch** cannot be superseded, so the walk that found it
    ///   waits, and a search paused behind a suspended app costs nothing;
    /// - **completion** is always sent, and drops whatever progress is still
    ///   waiting, so nothing arrives after it.
    ///
    /// The wire is unchanged: these are the same messages, fewer of them.
    public final class XPCEventPacer: @unchecked Sendable {
        /// How often a waiting batch looks at whether its job has been told to
        /// stop. A barrier that never fires — a peer suspended for good — must
        /// not hold the walk past a cancellation.
        static let waitInterval: DispatchTimeInterval = .milliseconds(100)

        private let send: (xpc_object_t) -> Void
        private let barrier: (@escaping () -> Void) -> Void
        /// Everything below is touched only on this queue. A barrier may run
        /// its block synchronously — on a cancelled connection it does — so the
        /// block only ever comes back here asynchronously, never under a lock.
        private let queue = DispatchQueue(label: "wiki.qaq.fila.daemon.events")
        private let delivered = DispatchSemaphore(value: 0)
        private var inFlight = false
        private var latest: xpc_object_t?
        private var finished = false

        public convenience init(connection: xpc_connection_t) {
            self.init(
                send: { xpc_connection_send_message(connection, $0) },
                barrier: { xpc_connection_send_barrier(connection, $0) },
            )
        }

        /// The transport, injectable so the pacing can be tested against a
        /// peer that never reads.
        init(send: @escaping (xpc_object_t) -> Void, barrier: @escaping (@escaping () -> Void) -> Void) {
            self.send = send
            self.barrier = barrier
        }

        /// A message the next one of its kind replaces: progress.
        public func sendLatest(_ message: xpc_object_t) {
            queue.sync {
                guard !finished else { return }
                if inFlight {
                    latest = message
                } else {
                    transmit(message)
                }
            }
        }

        /// A message that has to arrive: a search batch. Blocks the calling
        /// worker until the previous message has left this process, or until
        /// `stop` says the job is over, in which case the batch is dropped —
        /// its completion is about to say so.
        public func sendInOrder(_ message: xpc_object_t, stop: () -> Bool) {
            while true {
                // Every departure signals, waiter or not — progress departs
                // ten times a second — so what piled up is drained before
                // looking. Left in place, that count would let the wait below
                // return at once, over and over, behind a peer that has
                // stopped reading. A departure after this drain is either seen
                // as `inFlight == false` below or signals the wait.
                while delivered.wait(timeout: .now()) == .success {}
                let sent = queue.sync { () -> Bool in
                    if finished {
                        return true
                    }
                    guard !inFlight else { return false }
                    transmit(message)
                    return true
                }
                if sent || stop() {
                    return
                }
                _ = delivered.wait(timeout: .now() + Self.waitInterval)
            }
        }

        /// The last message for this job. Always sent, whatever is in flight.
        public func finish(_ message: xpc_object_t) {
            queue.sync {
                finished = true
                latest = nil
                send(message)
            }
        }

        private func transmit(_ message: xpc_object_t) {
            dispatchPrecondition(condition: .onQueue(queue))
            inFlight = true
            send(message)
            barrier { [self] in
                queue.async { self.departed() }
            }
        }

        private func departed() {
            dispatchPrecondition(condition: .onQueue(queue))
            inFlight = false
            delivered.signal()
            guard !finished, let next = latest else { return }
            latest = nil
            transmit(next)
        }
    }
#endif
