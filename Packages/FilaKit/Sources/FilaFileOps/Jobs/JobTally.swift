import CRemoveFile
import Darwin
import Dispatch
import FilaProtocol
import Foundation

/// What a running job has done so far, and the callbacks libSystem drives it
/// from.
///
/// Totals stay at zero throughout. Knowing them would mean walking every tree
/// before copying it, which doubles the work on the slowest thing the app does
/// — and `JobProgress.fraction` already models "unknown" as the difference
/// between a bar and a spinner.
final class JobTally {
    let job: FileJob
    /// The first thing that went wrong inside a libSystem walk.
    ///
    /// `copyfile(3)` with no callback aborts on the first entry it cannot read.
    /// A callback that answers `COPYFILE_CONTINUE` for an error stage turns
    /// that into "skip it and carry on", and `copyfile` then returns 0 — a
    /// partial copy reported as a complete one, which for a cross-volume move
    /// means deleting the originals of the files that did not make it. So the
    /// error stages stop the walk and leave the reason here.
    private(set) var failure: FilaFailure?

    private let report: (JobProgress) -> Void

    private var completedBytes: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var itemsDone: Int64 = 0
    /// What the job is touching right now, which is what the label under the
    /// bar says. Only `beginItem` writes it: a label that flicked back to the
    /// thing that just ended would name the wrong file half the time.
    private var currentPath = ""
    /// Far enough in the past that the first event is never throttled — a job
    /// short enough to finish inside one interval must still say something.
    private var lastReport = DispatchTime(uptimeNanoseconds: 1)

    init(job: FileJob, report: @escaping (JobProgress) -> Void) {
        self.job = job
        self.report = report
    }

    func beginItem(_ path: String) {
        currentPath = path
        currentFileBytes = 0
        emit(throttled: true)
    }

    func fileProgress(_ bytes: Int64) {
        currentFileBytes = bytes
        emit(throttled: true)
    }

    func finishedItem() {
        completedBytes += currentFileBytes
        currentFileBytes = 0
        itemsDone += 1
        emit(throttled: true)
    }

    /// The last word, sent unthrottled when the job is over so the bar lands on
    /// what actually happened rather than wherever the throttle left it.
    func flush() {
        emit(throttled: false)
    }

    /// Reads `errno` where the failing walk left it, so this must be the first
    /// thing the callback does on an error stage. Only the first is kept: what
    /// went wrong first is what the user needs to read.
    func recordFailure(_ path: String?) {
        guard failure == nil else { return }
        let code = Darwin.errno
        failure = FilaFailure(errno: code == 0 ? EIO : code, path: path)
    }

    /// A copy's failure, named by the side it is about. `copyfile(3)` does
    /// not say which end failed, but some errnos can only be the end being
    /// written: a read-only volume, or one without room.
    func recordCopyFailure(source: String?, destination: String?) {
        guard failure == nil else { return }
        let code = Darwin.errno
        let errno = code == 0 ? EIO : code
        failure = FilaFailure(errno: errno, path: filaFailsWriting(errno) ? destination ?? source : source)
    }

    func recordFailure(_ failure: FilaFailure) {
        if self.failure == nil {
            self.failure = failure
        }
    }

    /// A failed pass the job is about to redo another way, whose reason no
    /// longer describes the job — and would stop its next copy before it began.
    func forgetFailure() {
        failure = nil
    }

    /// Copying a large file fires the callback thousands of times a second and
    /// deleting a large tree fires it once per node. Every one of those would
    /// otherwise be an XPC message to a bar that cannot show more than a few a
    /// second, so every caller here is throttled and only `flush` is not.
    private func emit(throttled: Bool) {
        let now = DispatchTime.now()
        if throttled, now.uptimeNanoseconds &- lastReport.uptimeNanoseconds < 100_000_000 {
            return
        }
        lastReport = now
        report(JobProgress(
            bytesDone: completedBytes + currentFileBytes,
            bytesTotal: 0,
            itemsDone: itemsDone,
            itemsTotal: 0,
            currentPath: currentPath,
        ))
    }
}

/// Whether a failed copy's `errno` can only be about the destination: the
/// source is only ever read, and these refuse a write.
func filaFailsWriting(_ code: Int32) -> Bool {
    code == EROFS || code == ENOSPC || code == EDQUOT
}

/// `copyfile(3)`'s state callback: progress on the way past, and the one place
/// a cancellation can take effect.
let filaCopyProgress: copyfile_callback_t = { what, stage, state, source, destination, context in
    guard let context else { return COPYFILE_CONTINUE }
    let tally = Unmanaged<JobTally>.fromOpaque(context).takeUnretainedValue()
    // COPYFILE_QUIT makes copyfile return -1 with ECANCELED, which is exactly
    // how a job that was asked to stop reports itself.
    if tally.job.isCancelled {
        return COPYFILE_QUIT
    }

    // An error stage stops the walk. Answering CONTINUE here is what turns a
    // partial copy into a reported success — see `JobTally.failure`.
    if stage == COPYFILE_ERR || what == COPYFILE_RECURSE_ERROR {
        tally.recordCopyFailure(
            source: source.map { String(cString: $0) },
            destination: destination.map { String(cString: $0) },
        )
        return COPYFILE_QUIT
    }

    if stage == COPYFILE_START || stage == COPYFILE_PROGRESS {
        do {
            var descriptor: Int32 = -1
            if what == COPYFILE_COPY_DATA,
               copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &descriptor) == 0, descriptor >= 0
            {
                try StorageSpace.requireAvailable(descriptor: descriptor)
            } else if let destination {
                try StorageSpace.requireAvailable(at: FilaPath.directory(of: String(cString: destination)))
            }
        } catch let failure as FilaFailure {
            tally.recordFailure(failure)
            return COPYFILE_QUIT
        } catch {
            tally.recordFailure(FilaFailure(errno: EIO))
            return COPYFILE_QUIT
        }
    }

    switch (what, stage) {
    case (COPYFILE_RECURSE_FILE, COPYFILE_START), (COPYFILE_RECURSE_DIR, COPYFILE_START):
        tally.beginItem(source.map { String(cString: $0) } ?? "")
    case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS), (COPYFILE_COPY_DATA, COPYFILE_FINISH):
        var copied: off_t = 0
        if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
            tally.fileProgress(Int64(copied))
        }
    case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH), (COPYFILE_RECURSE_DIR, COPYFILE_FINISH):
        if what == COPYFILE_RECURSE_FILE, let source, let destination {
            do {
                try filaRestoreSetID(state: state, source: String(cString: source), clone: String(cString: destination))
            } catch let failure as FilaFailure {
                tally.recordFailure(failure)
                return COPYFILE_QUIT
            } catch {
                tally.recordFailure(FilaFailure(errno: EIO))
                return COPYFILE_QUIT
            }
        }
        tally.finishedItem()
    default:
        break
    }
    return COPYFILE_CONTINUE
}

/// A file `COPYFILE_CLONE` cloned has the source's mode without setuid and
/// setgid, and `COPYFILE_STATE_PRESERVE_SUID` cannot change that. A copy is
/// meant to be the same file — a copied bootstrap whose `sudo` lost its bit
/// is a broken one — so the clone gets the source's bits back, as a full copy
/// across volumes keeps them. By path, as copyfile itself works, and never
/// through a link. A flag that forbids the change is lifted around it.
private func filaRestoreSetID(state: copyfile_state_t?, source: String, clone: String) throws {
    var wasCloned = false
    guard copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &wasCloned) == 0, wasCloned else { return }
    let setID = mode_t(S_ISUID | S_ISGID)
    var original = stat()
    guard lstat(source, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
          original.st_mode & setID != 0 else { return }
    var copied = stat()
    try filaCheck(clone) { lstat(clone, &copied) }
    guard copied.st_mode & S_IFMT == S_IFREG, copied.st_mode & setID != original.st_mode & setID else { return }
    let immovable = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
    let flags = copied.st_flags
    if flags & immovable != 0 {
        try filaCheck(clone) { lchflags(clone, flags & ~immovable) }
    }
    try filaCheck(clone) { fchmodat(AT_FDCWD, clone, original.st_mode & 0o7777, AT_SYMLINK_NOFOLLOW) }
    if flags & immovable != 0 {
        try filaCheck(clone) { lchflags(clone, flags) }
    }
}

/// `removefile(3)`'s confirm callback. It fires once per node *before* that
/// node is removed, which makes it the cancellation point and, near enough, the
/// progress: the count runs one node ahead of the disk, and a delete that fails
/// stops the walk anyway.
let filaRemoveProgress: removefile_callback_t = { _, path, context in
    guard let context else { return Int32(REMOVEFILE_PROCEED) }
    let tally = Unmanaged<JobTally>.fromOpaque(context).takeUnretainedValue()
    if tally.job.isCancelled {
        return Int32(REMOVEFILE_STOP)
    }
    tally.beginItem(path.map { String(cString: $0) } ?? "")
    tally.finishedItem()
    return Int32(REMOVEFILE_PROCEED)
}
