import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

/// Cancellation at many points, overlapping jobs, and a name that changes
/// between the guard's decision and the syscall that acts on it.
@Suite("Races and cancellation", .serialized)
struct DecisionRaceTests {
    @Test(.timeLimit(.minutes(1)))
    func `cancelling a multi-item copy publishes only complete items`() {
        let scratch = HuntScratch("cancel-copy")
        var sources: [String] = []
        var snapshots: [String: [String: HuntEntry]] = [:]
        for index in 0 ..< 8 {
            let source = scratch.path("item-\(index)")
            huntBuildTree(at: source, seed: UInt64(100 + index), nodes: 25, options: HuntTreeOptions())
            sources.append(source)
            snapshots[source] = huntSnapshot(source)
        }
        var random = HuntRandom(seed: 0xC0C0)
        for round in 0 ..< 15 {
            let destination = scratch.directory("dst-\(round)")
            let job = FileJob(request: JobRequest(kind: .copy, sources: sources, destination: destination), operations: FileOperations(bootstrapRoot: ""))
            let delay = UInt32.random(in: 0 ..< 3000, using: &random)
            DispatchQueue.global().async {
                usleep(delay)
                job.cancel()
            }
            let outcome = job.run { _ in }
            #expect(outcome.code == .success || outcome.code == .cancelled, "round \(round): \(outcome)")
            for source in sources {
                let landed = destination + "/" + FilaPath.name(of: source)
                if exists(landed) {
                    let diff = huntDiff(snapshots[source]!, huntSnapshot(landed))
                    #expect(diff.isEmpty, "round \(round): partial publication \(diff.prefix(3))")
                }
                #expect(huntDiff(snapshots[source]!, huntSnapshot(source)).isEmpty)
            }
            #expect(huntLeftoverTemporaries(in: destination).isEmpty, "round \(round)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `two trash jobs racing on the same names keep every item and its origin`() throws {
        let scratch = HuntScratch("trash-race")
        let boot = scratch.directory("boot")
        let operations = FileOperations(bootstrapRoot: boot)
        var files: [String] = []
        for folder in 0 ..< 16 {
            scratch.directory("f\(folder)")
            files.append(scratch.file("f\(folder)/same.txt", "payload \(folder)"))
        }
        let halves = [Array(files[0 ..< 8]), Array(files[8...])]
        let group = DispatchGroup()
        let lock = NSLock()
        var outcomes: [FilaFailure] = []
        for half in halves {
            group.enter()
            DispatchQueue.global().async {
                // One job per file, interleaved with the other thread's jobs.
                for file in half {
                    let outcome = huntRunJob(JobRequest(kind: .delete, sources: [file], useTrash: true), operations)
                    lock.lock(); outcomes.append(outcome); lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        #expect(outcomes.allSatisfy { $0.code == .success }, "\(outcomes.filter { $0.code != .success })")
        let trash = FilaTrash.directory(under: boot)
        let names = try FileManager.default.contentsOfDirectory(atPath: trash)
        #expect(names.count == files.count, "\(names.sorted())")
        for name in names {
            let item = trash + "/" + name
            let origin = try #require(extendedAttribute(FilaTrash.originAttribute, at: item))
            let folder = (origin as NSString).deletingLastPathComponent
            let index = try #require(Int(((folder as NSString).lastPathComponent).dropFirst()))
            #expect(huntReadAll(item) == Array("payload \(index)".utf8), "\(name) records \(origin)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a replace racing a delete never leaves a partial or foreign file`() {
        let scratch = HuntScratch("replace-race")
        let operations = FileOperations(bootstrapRoot: "")
        let target = scratch.file("doc.txt", String(repeating: "A", count: 50000))
        let stop = StopSignal()
        let deleter = Thread {
            while !stop.isRaised {
                _ = huntRunJob(JobRequest(kind: .delete, sources: [target]), operations)
            }
        }
        deleter.start()
        let fills: [UInt8] = Array("BCDEFG".utf8)
        for index in 0 ..< 400 {
            let fill = fills[index % fills.count]
            let temporary = scratch.file(".fila-tmp-\(index)", bytes: [UInt8](repeating: fill, count: 50000))
            do {
                try operations.replaceItem(at: target, withTemporary: temporary)
            } catch {
                unlink(temporary) // the caller discards on failure, as AtomicSave does
            }
            if let bytes = huntReadAll(target), !bytes.isEmpty {
                #expect(bytes.count == 50000 && Set(bytes).count == 1, "torn content at \(index)")
            }
        }
        stop.raise()
        while !deleter.isFinished { usleep(1000) }
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: scratch.root)) ?? []).filter { $0.hasPrefix(".fila-tmp-") }
        #expect(leftovers.isEmpty, "\(leftovers.prefix(3))")
    }

    @Test(.timeLimit(.minutes(1)))
    func `overlapping copy and delete jobs on one tree do not touch anything outside it`() {
        let scratch = HuntScratch("overlap")
        let outside = scratch.directory("outside")
        huntBuildTree(at: outside + "/keep", seed: 4242, nodes: 30)
        let keep = huntSnapshot(outside + "/keep")
        let operations = FileOperations(bootstrapRoot: "")
        for round in 0 ..< 20 {
            let tree = scratch.path("tree-\(round)")
            huntBuildTree(at: tree, seed: UInt64(round), nodes: 40)
            _ = symlink(outside, tree + "/escape")
            let destination = scratch.directory("dst-\(round)")
            let group = DispatchGroup()
            var copyOutcome = FilaFailure(code: .success)
            group.enter()
            DispatchQueue.global().async {
                copyOutcome = huntRunJob(JobRequest(kind: .copy, sources: [tree], destination: destination), operations)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                usleep(UInt32(round * 50))
                _ = huntRunJob(JobRequest(kind: .delete, sources: [tree]), operations)
                group.leave()
            }
            group.wait()
            _ = copyOutcome
            #expect(huntLeftoverTemporaries(in: destination).isEmpty, "round \(round)")
            #expect(huntDiff(keep, huntSnapshot(outside + "/keep")).isEmpty, "round \(round): outside changed")
        }
    }

    /// The guard decides on a canonical string; the delete acts on that string
    /// later. A directory renamed and replaced by a symlink in between — by any
    /// other process — changes which node the string names.
    @Test
    func `a parent swapped for a symlink after the guard decided does not redirect a delete onto a protected node`() {
        let scratch = HuntScratch("swap")
        let boot = scratch.directory("boot")
        let protected = scratch.directory("boot/usr")
        scratch.file("boot/usr/libsystem", "irreplaceable")
        scratch.directory("work/usr")
        scratch.file("work/usr/scratch-file", "disposable")
        let operations = FileOperations(bootstrapRoot: boot)
        #expect(operations.isDestructionProtected(protected))
        #expect(!operations.isDestructionProtected(scratch.path("work/usr")))

        var swapped = false
        let outcome = huntRunJob(JobRequest(kind: .delete, sources: [scratch.path("work/usr")]), operations) { _, _ in
            guard !swapped else { return }
            swapped = true
            // Between resolution and removefile: work -> boot.
            _ = rename(scratch.path("work"), scratch.path("work-was"))
            _ = symlink(boot, scratch.path("work"))
        }
        #expect(swapped)
        #expect(exists(protected), "protected \(protected) was removed through the swapped parent (outcome \(outcome))")
        #expect(huntReadAll(protected + "/libsystem") == Array("irreplaceable".utf8))
    }

    @Test
    func `a parent swapped after the guard decided does not redirect a trash onto a protected node`() {
        let scratch = HuntScratch("swap-trash")
        let boot = scratch.directory("boot")
        let protected = scratch.directory("boot/Library")
        scratch.file("boot/Library/prefs", "irreplaceable")
        scratch.directory("work/Library")
        let operations = FileOperations(bootstrapRoot: boot)
        var swapped = false
        let outcome = huntRunJob(JobRequest(kind: .delete, sources: [scratch.path("work/Library")], useTrash: true), operations) { _, _ in
            guard !swapped else { return }
            swapped = true
            _ = rename(scratch.path("work"), scratch.path("work-was"))
            _ = symlink(boot, scratch.path("work"))
        }
        #expect(swapped)
        #expect(exists(protected), "protected \(protected) was moved into the trash (outcome \(outcome))")
    }

    /// An approved Replace was decided about one file. A folder above it
    /// swapped for a link before the copy starts must not make the root
    /// rename publish over a same-named file the guard never saw.
    @Test
    func `a parent swapped after the guard decided does not redirect a replacing copy`() {
        let scratch = HuntScratch("swap-copy")
        let source = scratch.file("doc.txt", "new contents")
        scratch.directory("work/dst")
        scratch.file("work/dst/doc.txt", "approved to replace")
        scratch.directory("elsewhere/dst")
        let victim = scratch.file("elsewhere/dst/doc.txt", "never seen by the guard")
        let operations = FileOperations(bootstrapRoot: "")

        var swapped = false
        let request = JobRequest(kind: .copy, sources: [source], destination: scratch.path("work/dst"), overwrite: true)
        let outcome = huntRunJob(request, operations) { _, _ in
            guard !swapped else { return }
            swapped = true
            // Between settling the target and publishing the copy: work -> elsewhere.
            _ = rename(scratch.path("work"), scratch.path("work-was"))
            _ = symlink(scratch.path("elsewhere"), scratch.path("work"))
        }
        #expect(swapped)
        #expect(outcome.code != .success, "the copy published through the swapped parent")
        #expect(huntReadAll(victim) == Array("never seen by the guard".utf8))
        #expect(huntLeftoverTemporaries(in: scratch.path("elsewhere/dst")).isEmpty)
        #expect(huntReadAll(scratch.path("work-was/dst/doc.txt")) == Array("approved to replace".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func `a recursive chmod never reaches outside its tree while a folder is swapped for a link`() throws {
        let scratch = HuntScratch("chmod-race")
        let outside = scratch.directory("outside")
        // Same names as inside each `sub`, so a walk redirected through a link
        // would find something to change.
        for index in 0 ..< 30 { scratch.file("outside/f\(index)", "x", mode: 0o644) }
        let tree = scratch.directory("tree")
        for folder in 0 ..< 40 {
            scratch.directory("tree/d\(folder)/sub")
            for index in 0 ..< 30 { scratch.file("tree/d\(folder)/sub/f\(index)", "x", mode: 0o644) }
        }
        let operations = FileOperations(bootstrapRoot: "")
        let stop = StopSignal()
        let swapper = Thread {
            var flip = false
            while !stop.isRaised {
                let victim = tree + "/d\(Int.random(in: 0 ..< 40))/sub"
                if !flip, rename(victim, victim + "-real") == 0 {
                    _ = symlink(outside, victim)
                    usleep(50)
                    _ = unlink(victim)
                    _ = rename(victim + "-real", victim)
                }
                flip.toggle()
            }
        }
        swapper.start()
        let deadline = Date().addingTimeInterval(3)
        // Directory-safe modes, so the walk keeps descending as a normal user.
        var mode: mode_t = 0o755
        while Date() < deadline {
            mode = mode == 0o755 ? 0o751 : 0o755
            _ = try? operations.setAttributes(AttributeChange(mode: mode, isRecursive: true), at: tree)
            let touched = (0 ..< 30).filter { permissions(of: outside + "/f\($0)") != 0o644 }
            if !touched.isEmpty {
                Issue.record("a recursive chmod of \(tree) changed \(touched.count) files outside it, e.g. f\(touched[0]) is now \(String(permissions(of: outside + "/f\(touched[0])") ?? 0, radix: 8))")
                break
            }
        }
        stop.raise()
        while !swapper.isFinished { usleep(1000) }
        #expect(permissions(of: outside) == 0o755)
    }
}

/// Tells a racing thread to stop, read under a lock on every turn of its loop.
private final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }
}
