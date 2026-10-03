import FilaProtocol
import Foundation

public enum ArchivePath {
    /// Finder's layout database and ZIP metadata directory are not user files.
    /// Other dotfiles, including ordinary names starting with `._`, stay intact.
    public static func isFinderMetadata(_ path: String) -> Bool {
        let names = components(of: path)
        return names.last == ".DS_Store" || names.contains("__MACOSX")
    }

    /// The kernel splits a path on the byte 0x2F and nothing else. A Swift
    /// `Character` does not: "/" followed by U+0301, a ZWJ or a variation
    /// selector is one grapheme that is not equal to "/", so `../\u{301}x`
    /// split on `Character`s is one harmless-looking component, and the
    /// kernel walks its `..`. Every split of a member name is over UTF-8.
    private static let slash = UInt8(ascii: "/")

    /// The non-empty components of `path`, split where the kernel splits.
    /// Splitting at an ASCII byte never cuts a UTF-8 sequence, so each one
    /// decodes back to exactly the bytes it was.
    public static func components(of path: String) -> [String] {
        path.utf8.split(separator: slash, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether `name` may be handed to an `*at` call as one component of a
    /// member's path: not empty, not `.` or `..`, and no `/` or NUL byte in
    /// it. Compared by bytes, which is how the kernel compares them — the
    /// same rule every prompt applies to a typed name.
    public static func isComponent(_ name: String) -> Bool {
        FilaGuard.isComponent(name)
    }

    /// Remove the compound tar suffix as one format, preserving dots in names.
    public static func extractionFolderName(for name: String) -> String {
        let file = (name as NSString).lastPathComponent
        let suffixes = [
            ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.zstd", ".tar.lzma", ".tar.lz4", ".tar.lz", ".tar.Z",
        ]
        if let suffix = suffixes.first(where: { file.lowercased().hasSuffix($0.lowercased()) }) {
            return String(file.dropLast(suffix.count))
        }
        return (file as NSString).deletingPathExtension
    }

    /// The most a name may take in a progress line, a note or a failure, in
    /// UTF-8 bytes. A path the filesystem can hold fits whole.
    static let maximumDisplayByteCount = Int(MAXPATHLEN)

    /// A name as a job may report it: control characters and line breaks
    /// shown as U+FFFD, cut at `maximumDisplayByteCount` with an ellipsis.
    ///
    /// **Display only** — placement uses the name itself. An archive may
    /// declare a name a megabyte long, every progress line and note carries
    /// it to a daemon launchd kills at 6 MB, and JSON spells each control
    /// character in six bytes.
    static func displayName(_ name: String) -> String {
        var shown = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in name.unicodeScalars {
            let visible: Unicode.Scalar = switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: "\u{FFFD}"
            default: scalar
            }
            byteCount += UTF8.width(visible)
            guard byteCount <= maximumDisplayByteCount else {
                shown.append("…")
                break
            }
            shown.append(visible)
        }
        return String(shown)
    }

    /// The one form of an entry name that may be appended to a destination.
    ///
    /// Checked by walking components, never by normalising the string:
    /// `FilaGuard.normalize` collapses a leading `..` against the root the way
    /// the kernel does, which is right for an absolute path and exactly wrong
    /// here — it would turn an escape into a legal-looking relative one.
    ///
    /// A NUL byte is refused rather than kept: the C string an `*at` call is
    /// given would end there, and the name checked would not be the name used.
    public static func validated(_ declared: String) -> String? {
        guard let first = declared.utf8.first, first != slash, !declared.utf8.contains(0) else { return nil }
        var kept: [String] = []
        for component in components(of: declared) {
            if component.utf8.elementsEqual(".".utf8) {
                continue
            }
            guard isComponent(component) else { return nil }
            kept.append(component)
        }
        return kept.isEmpty ? nil : kept.joined(separator: "/")
    }
}
