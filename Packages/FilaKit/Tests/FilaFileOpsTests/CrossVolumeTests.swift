import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

/// Real EXDEV paths: a small APFS sparse image mounted inside the scratch
/// directory. Skipped when the host will not attach an image at all; an
/// attach that fails on a host that can is a failure.
@Suite("Across volumes", .serialized, .enabled(if: huntCanAttachVolumes, "this host cannot attach a disk image"))
struct CrossVolumeTests {
    @Test(.timeLimit(.minutes(2)))
    func `cross-volume copy, move, trash and Put Back keep the tree`() throws {
        let scratch = HuntScratch("xvol")
        guard let volume = scratch.mountVolume("vol", megabytes: 900) else {
            Issue.record("hdiutil could not attach a scratch volume")
            return
        }
        #expect(!filaSameVolume(scratch.root, volume))
        let operations = FileOperations(bootstrapRoot: "")
        for seed: UInt64 in [11, 12] {
            let source = scratch.path("src-\(seed)")
            huntBuildTree(at: source, seed: seed, nodes: 40, options: HuntTreeOptions(immutable: false, fifo: false, hardLinks: true))
            let before = huntSnapshot(source)

            let copy = huntRunJob(JobRequest(kind: .copy, sources: [source], destination: volume), operations)
            #expect(copy.code == .success, "copy seed \(seed): \(copy)")
            let copyDiff = huntDiff(before, huntSnapshot(volume + "/src-\(seed)"))
            #expect(copyDiff.isEmpty, "copy seed \(seed): \(copyDiff.prefix(5))")
            #expect(huntLeftoverTemporaries(in: volume).isEmpty)
            huntUnlock(volume + "/src-\(seed)")
            _ = huntRunJob(JobRequest(kind: .delete, sources: [volume + "/src-\(seed)"]), operations)

            let move = huntRunJob(JobRequest(kind: .move, sources: [source], destination: volume), operations)
            #expect(move.code == .success, "move seed \(seed): \(move)")
            #expect(!exists(source))
            let moveDiff = huntDiff(before, huntSnapshot(volume + "/src-\(seed)"))
            #expect(moveDiff.isEmpty, "move seed \(seed): \(moveDiff.prefix(5))")

            // Trash from the image into a bootstrap on the scratch volume.
            let boot = scratch.directory("boot-\(seed)")
            let relocated = FileOperations(bootstrapRoot: boot)
            let identity = UUID()
            let trashed = huntRunJob(JobRequest(kind: .delete, sources: [volume + "/src-\(seed)"], useTrash: true, trashID: identity), relocated)
            #expect(trashed.code == .success, "trash seed \(seed): \(trashed)")
            let item = FilaTrash.directory(under: boot) + "/src-\(seed)"
            #expect(extendedAttribute(FilaTrash.originAttribute, at: item) == volume + "/src-\(seed)")
            let back = huntRunJob(JobRequest(kind: .restore, sources: [item], trashID: identity), relocated)
            #expect(back.code == .success, "put back seed \(seed): \(back)")
            let backDiff = huntDiff(before, huntSnapshot(volume + "/src-\(seed)"))
            #expect(backDiff.isEmpty, "put back seed \(seed): \(backDiff.prefix(5))")
            #expect(!exists(item))
            #expect(huntLeftoverTemporaries(in: FilaTrash.directory(under: boot)).isEmpty)
            #expect(huntLeftoverTemporaries(in: volume).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func `cross-volume copy keeps a sparse file sparse`() throws {
        let scratch = HuntScratch("xsparse")
        guard let volume = scratch.mountVolume("vol", megabytes: 900) else {
            Issue.record("hdiutil could not attach a scratch volume")
            return
        }
        let source = scratch.path("disk.img")
        let fd = open(source, O_CREAT | O_WRONLY, 0o644)
        try #require(fd >= 0)
        _ = lseek(fd, 128 * 1024 * 1024, SEEK_SET)
        _ = "tail".withCString { write(fd, $0, 4) }
        close(fd)
        let sourceBlocks = try #require(metadata(of: source)).st_blocks
        let outcome = huntRunJob(JobRequest(kind: .copy, sources: [source], destination: volume), FileOperations(bootstrapRoot: ""))
        #expect(outcome.code == .success, "\(outcome)")
        let copied = try #require(metadata(of: volume + "/disk.img"))
        #expect(copied.st_size == 128 * 1024 * 1024 + 4)
        // AGENTS.md: bulk copies preserve sparseness. A dense copy allocates the hole.
        #expect(
            Int64(copied.st_blocks) * 512 < 16 * 1024 * 1024,
            "source allocates \(Int64(sourceBlocks) * 512) bytes; the cross-volume copy allocates \(Int64(copied.st_blocks) * 512)",
        )
    }

    @Test(.timeLimit(.minutes(2)))
    func `a copy refused for space publishes nothing and leaves no staging`() throws {
        let scratch = HuntScratch("enospc")
        // Below StorageSpace's 256 MB reserve from the start.
        guard let volume = scratch.mountVolume("tiny", megabytes: 120) else {
            Issue.record("hdiutil could not attach a scratch volume")
            return
        }
        huntBuildTree(at: scratch.path("src"), seed: 77, nodes: 30)
        let before = huntSnapshot(scratch.path("src"))
        for kind in [FilaJobKind.copy, .move] {
            let outcome = huntRunJob(JobRequest(kind: kind, sources: [scratch.path("src")], destination: volume), FileOperations(bootstrapRoot: ""))
            #expect(outcome.systemError == ENOSPC, "\(kind): \(outcome)")
            #expect(!exists(volume + "/src"))
            #expect(huntLeftoverTemporaries(in: volume).isEmpty, "\(huntLeftoverTemporaries(in: volume))")
            #expect(huntDiff(before, huntSnapshot(scratch.path("src"))).isEmpty)
        }
        // Trash on that volume: a bootstrap there, the source on the scratch volume.
        let boot = volume + "/boot"
        #expect(mkdir(boot, 0o755) == 0)
        let trashed = huntRunJob(JobRequest(kind: .delete, sources: [scratch.path("src")], useTrash: true), FileOperations(bootstrapRoot: boot))
        #expect(trashed.code != .success)
        #expect(huntDiff(before, huntSnapshot(scratch.path("src"))).isEmpty, "a failed cross-volume trash changed the source")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: FilaTrash.directory(under: boot))) ?? []).isEmpty)
    }

    @Test(.timeLimit(.minutes(2)))
    func `cancelling a cross-volume move or trash at random points keeps the source whole`() throws {
        let scratch = HuntScratch("xcancel")
        guard let volume = scratch.mountVolume("vol", megabytes: 900) else {
            Issue.record("hdiutil could not attach a scratch volume")
            return
        }
        let boot = scratch.directory("boot")
        var random = HuntRandom(seed: 0xCA9C)
        for round in 0 ..< 10 {
            let name = "tree-\(round)"
            let source = volume + "/" + name
            huntBuildTree(at: source, seed: UInt64(round), nodes: 50, options: HuntTreeOptions(resourceFork: true))
            let before = huntSnapshot(source)
            let useTrash = round % 2 == 0
            let request = useTrash
                ? JobRequest(kind: .delete, sources: [source], useTrash: true)
                : JobRequest(kind: .move, sources: [source], destination: scratch.root)
            let job = FileJob(request: request, operations: FileOperations(bootstrapRoot: useTrash ? boot : ""))
            let delay = UInt32.random(in: 0 ..< 40000, using: &random)
            DispatchQueue.global().async {
                usleep(delay)
                job.cancel()
            }
            let outcome = job.run { _ in }
            let landed = useTrash ? FilaTrash.directory(under: boot) + "/" + name : scratch.path(name)
            if outcome.code == .success {
                #expect(!exists(source))
                #expect(huntDiff(before, huntSnapshot(landed, ignoringXattrs: huntTrashAttributes)).isEmpty, "round \(round)")
            } else if exists(landed) {
                // A published copy must be complete, whatever happened to the source.
                let diff = huntDiff(before, huntSnapshot(landed, ignoringXattrs: huntTrashAttributes))
                #expect(diff.isEmpty, "round \(round) \(outcome): published copy incomplete: \(diff.prefix(4))")
            } else {
                let diff = huntDiff(before, huntSnapshot(source))
                #expect(diff.isEmpty, "round \(round) \(outcome): nothing published but the source changed: \(diff.prefix(4))")
            }
            #expect(huntLeftoverTemporaries(in: scratch.root).isEmpty, "round \(round)")
            #expect(huntLeftoverTemporaries(in: FilaTrash.directory(under: boot)).isEmpty, "round \(round)")
        }
    }
}
