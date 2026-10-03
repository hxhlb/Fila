import Foundation

/// A nested archive pulled out into its own workspace directory, removed when
/// the last thing that reads it lets go.
///
/// The browser showing it holds one reference, its folders another, and an
/// extraction from it holds one until the job — and any password retry —
/// is over. Popping the screen while the helper has yet to open the file
/// must not delete the file out from under the job.
final class StagedArchive: Sendable {
    let file: URL

    init(file: URL) {
        self.file = file
    }

    deinit {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
