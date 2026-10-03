import Darwin
import Dispatch
import FilaProtocol
import Foundation

/// `fila-archive`, spawned for one job and read until it exits.
///
/// **What this spawns:** the one executable `FileOperations.archiveHelper`
/// names, with an argv of exactly itself and an empty environment. **As
/// whom:** whoever `filad` is. **What it refuses:** anything else. The job
/// goes down the child's standard input as one JSON document, the child's
/// standard output is the only thing read back, and every other descriptor
/// this process holds is closed before the child runs. There is no way to
/// name a different program or hand it an argument, and there is not going
/// to be one.
///
/// The bytes of the archive never enter this process: they flow between the
/// helper and the kernel, the same trade `openPath` makes for a descriptor.
/// What crosses the pipe is a progress line a few times a second.
enum ArchiveHelperRun {
    /// Blocks until the helper is reaped. Cancellation arrives through the
    /// job: `FileJob.cancel` signals the pid this attaches.
    static func run(
        helper: String,
        task: ArchiveHelperTask,
        job: FileJob,
        report: @escaping (JobProgress) -> Void,
        note: @escaping (String) -> Void,
    ) throws -> FilaFailure {
        let request = try JSONEncoder().encode(task)

        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { throw FilaFailure(errno: Darwin.errno, path: helper) }
        guard pipe(&fromChild) == 0 else {
            let failure = FilaFailure(errno: Darwin.errno, path: helper)
            close(toChild[0]); close(toChild[1])
            throw failure
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT is the descriptor sweep: only the two ends dup'd
        // above survive into the child. SETSIGDEF puts SIGPIPE back, which
        // libdispatch leaves ignored in this process. SETSIGMASK starts the
        // child with nothing blocked: this runs on a dispatch worker, whose
        // mask blocks SIGTERM, and a cancel sent while the helper was still
        // starting would stay pending there until its SIG_IGN threw it away.
        var defaulted = sigset_t()
        sigemptyset(&defaulted)
        sigaddset(&defaulted, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK),
        )

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        let spawned = posix_spawn(&pid, helper, &actions, &attributes, argv, envp)
        close(toChild[0])
        close(fromChild[1])
        guard spawned == 0 else {
            close(toChild[1]); close(fromChild[0])
            throw FilaFailure(errno: spawned, path: helper)
        }
        job.attachHelper(pid)

        // The child reads its task to end of file before it starts, so the
        // whole document goes down first and the pipe closes behind it.
        writeFully(request, to: toChild[1])
        close(toChild[1])

        var completion: FilaFailure?
        readLines(from: fromChild[0]) { line in
            guard let decoded = try? JSONDecoder().decode(ArchiveHelperLine.self, from: line) else { return }
            switch decoded {
            case let .progress(progress): report(progress)
            case let .note(text): note(text)
            case let .completed(outcome, skipped):
                completion = outcome
                job.skippedItems = max(0, skipped)
            }
        }
        close(fromChild[0])

        // Wait for the exit without reaping it, let go of the pid, then reap:
        // until `waitpid` the number still belongs to the helper's zombie,
        // so a cancel landing in between cannot signal whoever inherits it.
        var exited = siginfo_t()
        while waitid(P_PID, id_t(pid), &exited, WEXITED | WNOWAIT) < 0, Darwin.errno == EINTR {}
        job.detachHelper()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, Darwin.errno == EINTR {}

        if let completion {
            return completion
        }
        if job.isCancelled {
            return FilaFailure(code: .cancelled)
        }
        // Killed by jetsam, or a crash: the helper never got to say.
        note("fila-archive exited with status \(status) before reporting an outcome")
        return FilaFailure(code: .operationFailed, systemError: EIO, path: helper)
    }

    private static func writeFully(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let put = write(descriptor, base.advanced(by: sent), raw.count - sent)
                if put < 0 {
                    if Darwin.errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
                sent += put
            }
        }
    }

    /// The longest line read back. A real one is a few hundred bytes; one
    /// longer than this carries an archive member's name built to be huge —
    /// a megabyte of control characters escapes to six — and buffering,
    /// decoding and forwarding it is enough to get a 6 MB daemon killed. It is
    /// dropped whole, and never held past this.
    static let maximumLineLength = 64 * 1024

    static func readLines(from descriptor: Int32, _ each: (Data) -> Void) {
        var pending = Data()
        // Inside a line already over the limit: drop bytes up to its newline.
        var discarding = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let got = read(descriptor, &buffer, buffer.count)
            if got < 0 {
                if Darwin.errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            if got == 0 {
                break
            }
            var chunk = buffer[0 ..< got]
            while let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                if !discarding {
                    pending.append(contentsOf: chunk[..<newline])
                    if pending.count <= maximumLineLength {
                        each(pending)
                    }
                }
                pending.removeAll(keepingCapacity: true)
                discarding = false
                chunk = chunk[(newline + 1)...]
            }
            guard !discarding else { continue }
            pending.append(contentsOf: chunk)
            if pending.count > maximumLineLength {
                pending.removeAll()
                discarding = true
            }
        }
        if !discarding, !pending.isEmpty {
            each(pending)
        }
    }
}
