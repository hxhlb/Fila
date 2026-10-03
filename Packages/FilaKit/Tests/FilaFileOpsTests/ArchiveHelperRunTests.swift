import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

/// The pipe between `filad` and `fila-archive`, driven against a shell script
/// standing in for the helper: what the daemon writes down, what it reads
/// back, and what a cancel does to the child.
@Suite("Archive helper", .serialized)
struct ArchiveHelperRunTests {
    let scratch = Scratch()

    private func helper(_ body: String) -> String {
        scratch.file("helper.sh", contents: "#!/bin/sh\n" + body + "\n", mode: 0o755)
    }

    private func line(_ value: ArchiveHelperLine) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }

    private func request() -> JobRequest {
        JobRequest(kind: .compress, sources: [scratch.file("source")], destination: scratch.path("out.zip"), archive: ArchiveOptions())
    }

    @Test
    func `The task goes down as JSON, and progress, notes and the outcome come back by line`() throws {
        let progress = try line(.progress(JobProgress(bytesDone: 1, bytesTotal: 2, itemsDone: 3, itemsTotal: 4, currentPath: "x")))
        let note = try line(.note("skipped one"))
        let completed = try line(.completed(FilaFailure(code: .wrongPassword, path: "y"), skipped: 2))
        let script = helper("""
        task="$(cat)"
        case "$task" in *'"kind":5'*) ;; *) exit 3 ;; esac
        case "$task" in *'"bootstrapRoot":"'*) ;; *) exit 3 ;; esac
        printf '%s\\n' '\(progress)' '\(note)' '\(completed)'
        """)
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: script)
        var seen: [JobProgress] = []
        var notes: [String] = []
        let job = FileJob(request: request(), operations: operations)
        let outcome = job.run { seen.append($0) } note: { notes.append($0) }
        #expect(outcome.code == .wrongPassword)
        #expect(outcome.path == "y")
        #expect(job.skippedItems == 2)
        #expect(seen == [JobProgress(bytesDone: 1, bytesTotal: 2, itemsDone: 3, itemsTotal: 4, currentPath: "x")])
        #expect(notes == ["skipped one"])
    }

    @Test
    func `A helper that dies without an outcome is a failure, not a success`() {
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: helper("cat >/dev/null; exit 9"))
        var notes: [String] = []
        let outcome = FileJob(request: request(), operations: operations).run { _ in } note: { notes.append($0) }
        #expect(outcome.code == .operationFailed)
        #expect(notes.first?.contains("exited") == true)
    }

    @Test
    func `A missing helper fails with the errno rather than hanging`() {
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: scratch.path("absent"))
        let outcome = FileJob(request: request(), operations: operations).run { _ in }
        #expect(outcome.systemError == ENOENT)
    }

    /// A member name built to be huge comes back as one enormous line. The
    /// daemon must neither hold it nor decode it, and the lines around it must
    /// still arrive.
    @Test
    func `A line longer than the limit is dropped whole and the next one still arrives`() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        let oversized = ArchiveHelperRun.maximumLineLength + 1
        let writer = Thread {
            func send(_ bytes: [UInt8]) {
                var sent = 0
                while sent < bytes.count {
                    let put = bytes[sent...].withUnsafeBytes { write(ends[1], $0.baseAddress, $0.count) }
                    guard put > 0 else { return }
                    sent += put
                }
            }
            send(Array("first\n".utf8))
            // Arrives in many reads, and never with its newline in the first.
            send([UInt8](repeating: UInt8(ascii: "x"), count: oversized * 3))
            send(Array("\nlast\n".utf8))
            send([UInt8](repeating: UInt8(ascii: "y"), count: oversized))
            close(ends[1])
        }
        writer.start()
        var lines: [String] = []
        ArchiveHelperRun.readLines(from: ends[0]) { lines.append(String(decoding: $0, as: UTF8.self)) }
        close(ends[0])
        #expect(lines == ["first", "last"])
    }

    /// A cancel that reaches the helper before it has read its task must not
    /// be lost. The job runs on a dispatch worker, as it does in the daemon,
    /// and a worker's mask blocks SIGTERM: inherited, the signal would wait
    /// until the five-second SIGKILL.
    @Test
    func `A helper starts with no signal blocked, so an early cancel ends it at once`() {
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: helper("exec sleep 30"))
        let job = FileJob(request: request(), operations: operations)
        let finished = DispatchSemaphore(value: 0)
        var outcome = FilaFailure(code: .success)
        let started = Date()
        // On a queue of its own, as the daemon's `archiveQueue` is: a dispatch
        // worker with a worker's mask, which is what is under test, and one
        // that a saturated global pool cannot hold back.
        DispatchQueue(label: "wiki.qaq.fila.tests.archive-job").async {
            outcome = job.run { _ in }
            finished.signal()
        }
        Self.cancel(job, after: 0.3)
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(outcome.code == .cancelled)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test
    func `Cancel hangs the helper up and the job reports cancelled`() {
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: helper("cat >/dev/null; exec sleep 30"))
        let job = FileJob(request: request(), operations: operations)
        Self.cancel(job, after: 0.3)
        let started = Date()
        let outcome = job.run { _ in }
        #expect(outcome.code == .cancelled)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// A cancel on a thread of its own rather than a dispatch timer. With the
    /// whole suite running in parallel, a loaded machine can leave no global
    /// worker free for half a minute, and a cancel that never fires reads as a
    /// helper that ignored it.
    private static func cancel(_ job: FileJob, after seconds: Double) {
        Thread {
            usleep(useconds_t(seconds * 1_000_000))
            job.cancel()
        }.start()
    }
}
