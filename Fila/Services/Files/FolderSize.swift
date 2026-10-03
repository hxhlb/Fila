import FilaProtocol
import Foundation

/// What a folder holds, counted from the app the way `FileSearch` walks it.
///
/// The daemon is never asked to walk a tree (6 MB; see `FileSearch`), so the
/// frontier is here and every folder is read page by page. Links are not
/// followed — what a link points to belongs to somewhere else, and following
/// the links of a jailbroken filesystem counts `/private` several times over.
enum FolderSize {
    struct Totals: Equatable {
        /// Bytes of every file and link below the folder. A directory's own
        /// `st_size` is an artefact of the filesystem, not content, and is
        /// left out, which is what Finder shows too.
        var size: Int64 = 0
        /// Blocks in use by everything below it, directories included.
        var allocatedSize: Int64 = 0
        /// Files, folders and links below it, the folder itself not counted.
        var items = 0
        /// Folders that could not be listed; what is inside them is missing
        /// from the totals.
        var unreadableFolders = 0
    }

    /// Hands the running totals to `onProgress` at most every `interval`, and
    /// returns the final ones — or nil once the task is cancelled, which is
    /// what leaving the screen does.
    @MainActor
    static func count(
        _ root: String,
        session: FileSession,
        interval: TimeInterval = 0.25,
        onProgress: @MainActor (Totals) -> Void,
    ) async -> Totals? {
        var totals = Totals()
        // Each folder still to read, with the volume it is on: the mount
        // point it was reached through, or "" for the root's own volume.
        var frontier = [root]
        var volumes = [""]
        var next = 0
        // A file with several names is counted once, the way `du` does:
        // the blocks are shared, and adding them twice would promise space
        // that deleting the folder never gives back. By volume and inode —
        // inode numbers are per volume, and a walk from `/` crosses several.
        var linkedFiles: Set<LinkedFile> = []
        let mounts = await mountPoints(session: session)
        var reportedAt = Date()
        while next < frontier.count {
            let directory = frontier[next]
            let volume = volumes[next]
            frontier[next] = ""
            next += 1
            // Pages of a live directory can repeat a name; see `FileSearch`.
            var seen: Set<String> = []
            do {
                for try await page in DirectoryReader.pages(in: directory, session: session) {
                    for node in page where seen.insert(node.name).inserted {
                        totals.items += 1
                        if node.kind == .directory {
                            totals.allocatedSize += node.allocatedSize
                            let child = directory == "/" ? "/" + node.name : directory + "/" + node.name
                            frontier.append(child)
                            volumes.append(mounts.contains(volumeKey(child)) ? child : volume)
                            continue
                        }
                        if node.linkCount > 1,
                           !linkedFiles.insert(LinkedFile(volume: volume, inode: node.inode)).inserted
                        {
                            continue
                        }
                        totals.size += node.size
                        totals.allocatedSize += node.allocatedSize
                    }
                    if Date().timeIntervalSince(reportedAt) >= interval {
                        reportedAt = Date()
                        onProgress(totals)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                totals.unreadableFolders += 1
            }
            guard !Task.isCancelled else { return nil }
        }
        return totals
    }

    private struct LinkedFile: Hashable {
        var volume: String
        var inode: UInt64
    }

    /// Every mount point, as `volumeKey` spells it. Empty where the mount
    /// table cannot be read — a container — and a walk then counts as one
    /// volume, which is all a container can reach anyway.
    @MainActor
    private static func mountPoints(session: FileSession) async -> Set<String> {
        let mounts = try? await session.perform(retryOnDisconnect: true) { try await $0.mountPoints() }
        return Set((mounts ?? []).map { volumeKey($0.path) })
    }

    /// A walk names folders the way it reached them, and `/var` is a link to
    /// `/private/var`: the mount table's `/private/var` must still match.
    private static func volumeKey(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
