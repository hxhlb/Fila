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

    /// Set while a copy walks a tree onto the volume it came from, where each
    /// file is a clone that costs nothing. Only bytes actually written are
    /// checked against the reserve then; a nearly full device can still copy
    /// a folder for free, as the whole-folder clone always let it.
    var clonesInPlace = false

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

    /// A failed pass the job is about to redo another way. Its reason no
    /// longer describes the job, and left here it would fail the job's next
    /// tree copy once that copy had finished.
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
    // A quit for cancellation records nothing: `FileJob.copyTree` reads the
    // job's own state, because copyfile leaves no errno that says why.
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
            } else if !tally.clonesInPlace, let destination {
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

/// A file copyfile cloned, given back the setuid and setgid bits cloning
/// leaves off. Its folder is reopened with `O_NOFOLLOW_ANY` first, because
/// copyfile names it by path and a root process must not chmod whatever that
/// path reaches by now.
private func filaRestoreSetID(state: copyfile_state_t?, source: String, clone: String) throws {
    var wasCloned = false
    guard copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &wasCloned) == 0, wasCloned else { return }
    var original = stat()
    guard lstat(source, &original) == 0 else { return }
    try filaWithDirectory(FilaPath.directory(of: clone)) { directory in
        try filaRestoreSetID(of: FilaPath.name(of: clone), in: directory, path: clone, source: original)
    }
}

/// A clone has the source's mode without setuid and setgid — clonefile(2)
/// clears them, and `COPYFILE_STATE_PRESERVE_SUID` cannot change that. A copy
/// is meant to be the same file, and a copied bootstrap whose `sudo` lost its
/// bit is a broken one, so the clone gets the source's two bits back, as a
/// full copy keeps them.
///
/// Only onto the clone of that source: one name, the same owner, size, time
/// and permission bits, so a source changed or a node swapped in since the
/// clone gets nothing. Only the two bits are added. A flag that forbids the
/// change is lifted around it; one that cannot be lifted, a system flag
/// without the privilege, leaves the clone as cloning left it rather than
/// failing a copy whose bytes are all there.
func filaRestoreSetID(of name: String, in directory: Int32, path: String, source: stat) throws {
    let setID = mode_t(S_ISUID | S_ISGID)
    guard source.st_mode & S_IFMT == S_IFREG, source.st_mode & setID != 0 else { return }
    var copied = stat()
    try filaCheck(path) { fstatat(directory, name, &copied, AT_SYMLINK_NOFOLLOW) }
    guard copied.st_mode & S_IFMT == S_IFREG, copied.st_nlink == 1,
          copied.st_uid == source.st_uid, copied.st_gid == source.st_gid,
          copied.st_size == source.st_size,
          copied.st_mtimespec.tv_sec == source.st_mtimespec.tv_sec,
          copied.st_mtimespec.tv_nsec == source.st_mtimespec.tv_nsec,
          copied.st_mode & 0o1777 == source.st_mode & 0o1777,
          copied.st_mode & setID != source.st_mode & setID
    else { return }
    let immovable = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
    let flags = copied.st_flags
    if flags & immovable != 0 {
        do {
            try filaSetFlags(flags & ~immovable, of: name, in: directory, path: path)
        } catch let failure as FilaFailure where failure.systemError == EPERM {
            return
        }
    }
    try filaCheck(path) {
        fchmodat(directory, name, (copied.st_mode & 0o7777) | (source.st_mode & setID), AT_SYMLINK_NOFOLLOW)
    }
    if flags & immovable != 0 {
        try filaSetFlags(flags, of: name, in: directory, path: path)
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
