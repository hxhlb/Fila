import Foundation

/// The one thing standing between a root file manager and a brick.
///
/// The rule is narrow on purpose: a node on this list may not itself be deleted,
/// moved away, or replaced — but everything *inside* it stays editable, because
/// editing files inside `/System` and `/var/mobile` is the entire point of the
/// app. Refusing whole subtrees would make Fila useless; refusing nothing makes
/// one mistyped gesture unrecoverable.
///
/// This lives in FilaProtocol so the harness can test it on macOS, but only the
/// daemon is allowed to *enforce* it. The client is untrusted UI: it may grey a
/// menu item out as a courtesy, and that is all it may do.
public enum FilaGuard {
    /// Paths that are refused as the target of a destructive operation.
    ///
    /// `bootstrapRoot` is where the jailbreak installed us — randomized on
    /// roothide, `/var/jb` on rootless, empty on a rootful layout — and is
    /// derived from the daemon's own `proc_pidpath`, never hardcoded. Deleting
    /// it takes the jailbreak, and Fila, with it.
    public static func protectedRoots(bootstrapRoot: String) -> [String] {
        var roots = [
            "/",
            "/Applications",
            "/Library",
            "/System",
            "/bin",
            "/cores",
            "/dev",
            "/opt",
            "/private",
            "/private/etc",
            "/private/preboot",
            "/private/tmp",
            "/private/var",
            "/private/var/containers",
            "/private/var/db",
            "/private/var/mobile",
            "/private/var/mobile/Containers",
            "/private/var/mobile/Library",
            "/private/var/root",
            "/sbin",
            "/usr",
            // Host-harness paths: tests run on macOS and must not delete the Mac.
            "/Network",
            "/System/Volumes",
            "/Users",
            "/Volumes",
        ]
        let root = normalize(bootstrapRoot)
        if root != "/" {
            roots.append(root)
            // The bootstrap's own top-level directories are as fatal as the
            // rootful ones they shadow.
            roots.append(contentsOf: ["/Applications", "/Library", "/usr", "/var", "/etc"].map { root + $0 })
        }
        return roots
    }

    /// Whether `path` may not be deleted, moved away, or overwritten.
    ///
    /// Pass a path that has already been through `realpath(3)`: `/var` and
    /// `/etc` are symlinks into `/private` on every Apple platform, and a
    /// listing that walked in through one of them would otherwise slip past a
    /// literal comparison. The lexical `normalize` below is defence in depth,
    /// not a substitute.
    public static func isDestructionProtected(_ path: String, bootstrapRoot: String) -> Bool {
        let target = normalize(path)
        return protectedRoots(bootstrapRoot: bootstrapRoot).contains { root in
            let root = normalize(root)
            // Equal — deleting the node itself.
            // Ancestor — deleting `/private` takes `/private/var` with it.
            return target == root || isAncestor(target, of: root)
        }
    }

    /// True when `ancestor` contains `path`. `/private` contains
    /// `/private/var`; `/priv` does not.
    public static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        let ancestor = components(of: ancestor)
        let path = components(of: path)
        return path.count > ancestor.count && path.starts(with: ancestor)
    }

    /// Lexical cleanup: absolute, no repeated or trailing slashes, `.` dropped,
    /// `..` resolved against what came before. Never touches the filesystem.
    public static func normalize(_ path: String) -> String {
        "/" + components(of: path).joined(separator: "/")
    }

    /// Whether `name` is exactly one entry's name, never a path: not empty,
    /// not `.` or `..`, and no `/` or NUL byte in it. Every prompt that names
    /// a new or renamed item asks this before joining the name to a folder.
    /// Compared by bytes for the reason `components(of:)` splits by bytes:
    /// `"../\u{301}x".contains("/")` is false, because "/" plus U+0301 is one
    /// `Character`, and the kernel would still read it as `..` and `\u{301}x`.
    public static func isComponent(_ name: String) -> Bool {
        let bytes = name.utf8
        return !bytes.isEmpty && !bytes.contains(UInt8(ascii: "/")) && !bytes.contains(0)
            && !bytes.elementsEqual(".".utf8) && !bytes.elementsEqual("..".utf8)
    }

    /// The components `normalize` keeps, split where the kernel splits: on the
    /// byte 0x2F. Splitting `Character`s would glue a name that starts with a
    /// combining mark, a ZWJ or a variation selector to the separator before
    /// it — "/" plus U+0301 is one grapheme and not equal to "/" — and
    /// `/a/tree/\u{301}inner` would stop being inside `/a/tree`.
    private static func components(of path: String) -> [String] {
        var components: [String] = []
        for bytes in path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true) {
            let component = String(decoding: bytes, as: UTF8.self)
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }
        return components
    }
}
