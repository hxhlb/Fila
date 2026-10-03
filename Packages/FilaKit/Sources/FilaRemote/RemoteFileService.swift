import FilaProtocol
import Foundation

/// The slice of `filad` the network features need.
///
/// A protocol rather than `DaemonLink` itself for one reason: this package has
/// to be exercised by `swift test` on a Mac with no daemon, no XPC and no Xcode,
/// and a server that hands out the root filesystem is the last thing in this
/// project that should be shipped untested. There are exactly two conformances
/// — the app's pass-through to `DaemonLink`, and the harness's one over a
/// scratch directory — and there will not be a third.
///
/// Every method here is a daemon operation and nothing else. The server never
/// calls `open(2)`, `unlink(2)` or `stat(2)` itself: the app runs as `mobile`
/// and would serve only what `mobile` can reach, and — far worse — a write that
/// did not travel through the daemon would not meet `FilaGuard`.
public protocol RemoteFileService: Sendable {
    /// Every entry of a directory. The daemon pages; the conformance is what
    /// hides that, because a listing that stops halfway is a listing that hides
    /// the user's files from their own Mac.
    func list(_ directory: String) async throws -> [FileNode]

    func details(of path: String) async throws -> FileDetails

    /// A descriptor the daemon opened. **The caller owns it and closes it.**
    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32

    func create(_ template: NodeTemplate, at path: String) async throws
    func setAttributes(_ change: AttributeChange, at path: String) async throws

    /// `exclusive` maps to the kernel's own check-and-move, which is what keeps
    /// a `MOVE` with `Overwrite: F` from destroying a file that appeared between
    /// the check and the call.
    func rename(_ source: String, to destination: String, exclusive: Bool) async throws

    /// Put a temporary the caller has finished writing in place of `target`.
    /// The only way anything in this package writes a file.
    func replaceItem(at target: String, withTemporary temporary: String) async throws

    /// Run a copy, move or delete to completion, or throw. A DAV client is
    /// holding a socket open waiting for the verdict, so unlike everywhere else
    /// in the app this one cannot be fire-and-forget.
    func run(_ job: JobRequest) async throws
}

public extension RemoteFileService {
    /// Where `path` actually lands once every symlink in it has been followed
    /// — the path the kernel will reach when a verb opens, creates or renames
    /// it — or nil when that cannot be settled.
    ///
    /// `details` canonicalises a path's parents and reports its last
    /// component as `lstat` finds it, so a final link is followed here, as
    /// many times as it takes: a link to a link is one hop the kernel takes
    /// and a one-hop check does not. A path that does not exist yet — the
    /// target of a `PUT` or a `MKCOL`, or anything under a directory that a
    /// link stands in for — is the resolved place of its nearest existing
    /// ancestor with the rest of its names after it, because that is where
    /// the kernel would create it.
    ///
    /// Nil, which a caller must read as *refused*, for a link it cannot read,
    /// a chain longer than the kernel's own `MAXSYMLINKS`, a name the walk
    /// cannot place — a `..` past a component that does not exist — or a
    /// lookup that failed for any reason but absence: a link whose own
    /// lookup dropped points somewhere nobody knows, and its name says
    /// nothing about where.
    func resolvedPath(of path: String) async -> String? {
        var current = path
        var remainder: [String] = []
        var hops = 0
        while true {
            let found: FileDetails?
            do {
                found = try await details(of: current)
            } catch let failure as FilaFailure where failure.systemError == ENOENT || failure.systemError == ENOTDIR {
                found = nil
            } catch {
                return nil
            }
            guard let details = found else {
                // Not there: judged by where it would be.
                guard current != "/", current.hasPrefix("/") else { return nil }
                let name = RemotePath.name(of: current)
                guard name != ".", name != ".." else { return nil }
                remainder.insert(name, at: 0)
                current = RemotePath.parent(of: current)
                continue
            }
            guard details.node.kind == .symbolicLink else {
                return remainder.reduce(details.path) { RemotePath.join($0, $1) }
            }
            hops += 1
            guard hops <= Int(MAXSYMLINKS), let target = details.node.link?.target, !target.isEmpty else {
                return nil
            }
            current = target.hasPrefix("/")
                ? target
                : RemotePath.join(RemotePath.parent(of: details.path), target)
        }
    }
}
