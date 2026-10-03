import Darwin
import Dispatch
import FilaFileOps
import FilaFormats
import FilaProtocol
import Foundation

// `fila-archive`: the process `filad` spawns for one compress or extract.
//
// One `ArchiveHelperTask` as JSON on standard input, `ArchiveHelperLine`s one
// per line on standard output, `SIGTERM` to stop. It runs as whoever spawned
// it — root on a device — and touches the filesystem only through
// `FileOperations`, so the guard and the atomic replace are the daemon's own.
// See `ArchiveHelperRun` for the other side of the pipe, and
// `FilaJobKind.compress` for why this is a process at all.

let output = FileHandle.standardOutput
let encoder = JSONEncoder()

/// `FileHandle.write` is one `write(2)`, so a line lands whole or, when the
/// daemon has gone, raises the SIGPIPE that ends this process.
func emit(_ line: ArchiveHelperLine) {
    guard var data = try? encoder.encode(line) else { return }
    data.append(UInt8(ascii: "\n"))
    output.write(data)
}

/// A cancel that can arrive before there is a job to cancel: Cancel tapped
/// while this process is still reading its task.
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var job: ArchiveJob?

    func request() {
        lock.lock()
        requested = true
        let job = job
        lock.unlock()
        job?.cancel()
    }

    func attach(_ job: ArchiveJob) {
        lock.lock()
        self.job = job
        let requested = requested
        lock.unlock()
        if requested {
            job.cancel()
        }
    }
}

// Ignored at the signal level and delivered as an event instead, so the job
// stops at its next chunk and cleans up its temporary rather than leaving one.
//
// All of it before standard input is read. SIGTERM is blocked first, so one
// sent before the source is registered stays pending instead of ending the
// process; once registration has finished, the source sees every later one,
// and the pending check below catches any earlier one before `SIG_IGN`
// discards it.
let cancellation = Cancellation()
var terminate = sigset_t()
sigemptyset(&terminate)
sigaddset(&terminate, SIGTERM)
pthread_sigmask(SIG_BLOCK, &terminate, nil)
let registered = DispatchSemaphore(value: 0)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
stop.setRegistrationHandler { registered.signal() }
stop.setEventHandler { cancellation.request() }
stop.activate()
registered.wait()
var pending = sigset_t()
if sigpending(&pending) == 0, sigismember(&pending, SIGTERM) == 1 {
    cancellation.request()
}
signal(SIGTERM, SIG_IGN)
pthread_sigmask(SIG_UNBLOCK, &terminate, nil)

guard let task = try? JSONDecoder()
    .decode(ArchiveHelperTask.self, from: FileHandle.standardInput.readDataToEndOfFile())
else {
    emit(.completed(FilaFailure(code: .invalidRequest, systemError: EINVAL), skipped: 0))
    exit(EX_DATAERR)
}

let job = ArchiveJob(request: task.request, operations: FileOperations(bootstrapRoot: task.bootstrapRoot))
cancellation.attach(job)

let outcome = job.run(report: { emit(.progress($0)) }, note: { emit(.note($0)) })
emit(.completed(outcome, skipped: job.skippedItems))
exit(outcome.code == .success ? EXIT_SUCCESS : EXIT_FAILURE)
