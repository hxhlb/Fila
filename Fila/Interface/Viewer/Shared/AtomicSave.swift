import AlertController
import FilaClient
import FilaLog
import FilaProtocol
import Foundation
import UIKit

/// The only way an editor in this app writes a file.
///
/// Write a temporary beside the target, then ask the daemon to put it in place:
/// `replaceItem` carries the original's mode, owner, creation time, xattrs and
/// BSD flags across and `rename(2)`s, so a power cut during a save leaves either the old
/// file or the new one and never half of either. A half-written launchd plist is
/// a boot loop on a phone that cannot be booted into anything else.
///
/// The temporary is created `O_CREAT | O_EXCL` under a name nothing else would
/// pick, because an editor that can be raced into writing through a symlink an
/// attacker planted is an editor that writes anywhere as root.
///
/// Every editor here routes through this one function. There is deliberately no
/// second path and no `O_TRUNC` anywhere in the app: truncating over the
/// original destroys a file the user may have no copy of.
enum AtomicSave {
    static func write(_ data: Data, to path: String, link: any LocalFileAccess) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = (directory as NSString)
            .appendingPathComponent(".fila-tmp-\(UUID().uuidString)")

        let file = try await DescriptorFile.open(
            temporary,
            flags: O_CREAT | O_EXCL | O_WRONLY,
            mode: 0o600,
            link: link,
        )
        do {
            try file.write(data)
            file.close()
        } catch {
            file.close()
            await FileSession.shared.discardTemporary(temporary)
            throw error
        }

        do {
            try await link.replaceItem(at: path, withTemporary: temporary)
        } catch {
            await FileSession.shared.discardTemporary(temporary)
            throw error
        }
        // Every write an editor in this app makes, in the one place they all
        // go through. The byte count, never a byte: a save that "did nothing"
        // and a save of an empty document look identical from the outside.
        FilaLog.info("saved \(data.count) bytes to \(path)")
    }

    /// The file a save to `path` has to replace: `path` itself, or — when it
    /// is a symbolic link — the file at the end of its chain.
    ///
    /// `replaceItem` renames over the name it is given and never follows a
    /// link there, so saving to the link's own path would put a regular file
    /// where the link was and leave the file it pointed at unchanged. Each hop
    /// is asked of the backend, so the daemon canonicalises and guards the
    /// real target rather than a string resolved here; a relative target is
    /// read against the folder the link is actually in, and its `..` is left
    /// for `realpath(3)` there, because a lexical one is wrong across a link.
    static func target(of path: String, link: any LocalFileAccess) async throws -> FileDetails {
        var details = try await link.details(of: path)
        var hops = 0
        while details.node.kind == .symbolicLink {
            // The kernel's own limit, `MAXSYMLINKS`.
            guard hops < 32, let target = details.node.link?.target, !target.isEmpty else {
                throw FilaFailure(errno: ELOOP, path: path)
            }
            hops += 1
            let folder = (details.path as NSString).deletingLastPathComponent
            details = try await link.details(of: target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target))
        }
        return details
    }

    /// An editor's save: the file a link leads to, written only if it is
    /// still the one the editor read — or the person says to replace what
    /// is there now.
    ///
    /// Tabs keep an editor for as long as they like, and in that time another
    /// tab, a paste or a package manager can write the same file. Compared by
    /// inode, size and modification time: a save through `replaceItem`
    /// changes the inode, a write in place keeps the inode and changes the
    /// time.
    ///
    /// `loaded` nil skips the check.
    @MainActor
    static func save(
        _ data: Data,
        to path: String,
        expecting loaded: FileIdentity?,
        link: any LocalFileAccess,
        from presenter: UIViewController,
    ) async throws -> Outcome {
        let target = try await Self.target(of: path, link: link)
        if let loaded, FileIdentity(target.node) != loaded {
            let replace = await CardQuestion.ask(whenGone: false, from: presenter) { reply in
                AlertViewController(
                    title: String.LocalizationValue("File Changed on Disk"),
                    message: String.LocalizationValue("This file was changed after you opened it. Saving replaces those changes with yours."),
                ) { context in
                    context.addAction(title: String.LocalizationValue("Cancel")) { reply(context, false) }
                    context.addAction(title: String.LocalizationValue("Replace"), attribute: .accent) { reply(context, true) }
                }
            }
            guard replace else { return .kept }
        }
        try await write(data, to: target.path, link: link)
        // The new inode. Unknown only if the file went again at once, and
        // then the next save has nothing it could fairly compare against.
        let written = try? await link.details(of: target.path)
        return .saved(written.map { FileIdentity($0.node) })
    }

    enum Outcome {
        /// Written. Carries what is on disk now, to compare on the next save.
        case saved(FileIdentity?)
        /// The file had changed and the person chose to keep it.
        case kept
    }
}

/// What an editor read: enough to tell, at save time, whether the file on
/// disk is still that one.
struct FileIdentity: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var modified: Double

    init(inode: UInt64, size: Int64, modified: Double) {
        self.inode = inode
        self.size = size
        self.modified = modified
    }

    init(_ node: FileNode) {
        self.init(inode: node.inode, size: node.size, modified: node.modified)
    }
}
