import Darwin
@testable import FilaProtocol
import Foundation
import Testing

// Property tests over generated spellings. Seeded, so a failure reproduces.

private struct HuntRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let huntAlphabet = ["a", "b", "usr", "var", "private", "mobile", ".", "..", "", "x y", "é", "e\u{301}", "jb", "Library"]

/// A lexical respelling of `path` that names the same node without touching
/// the filesystem: doubled separators, `.` components, `name/..` detours and
/// a trailing separator.
private func respell(_ path: String, using random: inout HuntRandom) -> String {
    let components = path.split(separator: "/").map(String.init)
    var out = ""
    for component in components {
        switch Int.random(in: 0 ..< 5, using: &random) {
        case 0: out += "//" + component
        case 1: out += "/./" + component
        case 2: out += "/detour/../" + component
        case 3: out += "/" + component + "/."
        default: out += "/" + component
        }
    }
    if out.isEmpty { out = "/" }
    if Bool.random(using: &random) { out += "/" }
    if Bool.random(using: &random) { out = "/" + out }
    return out
}

@Suite("Guard properties")
struct GuardPropertyTests {
    private let bootstraps = ["", "/private/var/jb", "/private/preboot/ABCD/jb-x/procursus", "/private/var/containers/Bundle/Application/.jbroot-1234"]

    @Test
    func `normalize is idempotent, absolute and free of dot components`() {
        var random = HuntRandom(seed: 0xF11A)
        for _ in 0 ..< 20000 {
            let count = Int.random(in: 0 ..< 9, using: &random)
            var path = Bool.random(using: &random) ? "/" : ""
            for _ in 0 ..< count {
                path += huntAlphabet.randomElement(using: &random)! + (Bool.random(using: &random) ? "/" : "//")
            }
            let once = FilaGuard.normalize(path)
            #expect(FilaGuard.normalize(once) == once, "not idempotent: \(path.debugDescription) -> \(once.debugDescription)")
            #expect(once.hasPrefix("/"))
            #expect(once == "/" || !once.hasSuffix("/"))
            #expect(!once.contains("//"))
            let parts = once.split(separator: "/")
            #expect(!parts.contains("."))
            #expect(!parts.contains(".."))
        }
    }

    @Test
    func `every lexical respelling of a protected root stays protected`() {
        var random = HuntRandom(seed: 0x6A2D)
        for bootstrap in bootstraps {
            for root in FilaGuard.protectedRoots(bootstrapRoot: bootstrap) {
                for _ in 0 ..< 200 {
                    let spelling = respell(root, using: &random)
                    #expect(
                        FilaGuard.isDestructionProtected(spelling, bootstrapRoot: bootstrap),
                        "\(spelling.debugDescription) escaped the guard (root \(root), bootstrap \(bootstrap.debugDescription))",
                    )
                }
                // An ancestor of a protected node is as destructive as the node.
                var parent = root
                while let slash = parent.lastIndex(of: "/"), parent != "/" {
                    parent = slash == parent.startIndex ? "/" : String(parent[..<slash])
                    #expect(FilaGuard.isDestructionProtected(parent, bootstrapRoot: bootstrap))
                }
            }
        }
    }

    @Test
    func `a sibling that only shares a string prefix with a protected root is not protected`() {
        var random = HuntRandom(seed: 0x51B1)
        for bootstrap in bootstraps {
            let roots = FilaGuard.protectedRoots(bootstrapRoot: bootstrap).map(FilaGuard.normalize)
            for root in roots where root != "/" {
                for suffix in ["x", "-old", ".bak", " 2", "\u{301}x"] {
                    let sibling = root + suffix
                    let shouldProtect = roots.contains { $0 == FilaGuard.normalize(sibling) || FilaGuard.isAncestor(FilaGuard.normalize(sibling), of: $0) }
                    #expect(FilaGuard.isDestructionProtected(sibling, bootstrapRoot: bootstrap) == shouldProtect, "\(sibling)")
                    _ = random.next()
                }
                // Children are editable unless they are themselves on the list.
                let child = root + "/child-\(random.next() % 1000)"
                #expect(!FilaGuard.isDestructionProtected(child, bootstrapRoot: bootstrap))
            }
        }
    }

    @Test
    func `isAncestor is a strict partial order on normalized paths`() {
        var random = HuntRandom(seed: 0xA11C)
        let pool = ["/", "/a", "/a/b", "/a/b/c", "/ab", "/a/bc", "/b", "/a/b/c/d", "/é", "/e\u{301}"]
        for _ in 0 ..< 5000 {
            let x = pool.randomElement(using: &random)!
            let y = pool.randomElement(using: &random)!
            let z = pool.randomElement(using: &random)!
            #expect(!FilaGuard.isAncestor(x, of: x))
            if FilaGuard.isAncestor(x, of: y) {
                #expect(!FilaGuard.isAncestor(y, of: x))
                if FilaGuard.isAncestor(y, of: z) {
                    #expect(FilaGuard.isAncestor(x, of: z))
                }
            }
        }
    }

    @Test
    func `the bootstrap root is protected under every respelling of the bootstrap itself`() {
        var random = HuntRandom(seed: 0xB007)
        for bootstrap in bootstraps where !bootstrap.isEmpty {
            for _ in 0 ..< 200 {
                let configured = respell(bootstrap, using: &random)
                #expect(FilaGuard.isDestructionProtected(bootstrap, bootstrapRoot: configured))
                #expect(FilaGuard.isDestructionProtected(bootstrap + "/usr", bootstrapRoot: configured))
                #expect(!FilaGuard.isDestructionProtected(bootstrap + "/usr/bin", bootstrapRoot: configured))
            }
        }
    }

    @Test
    func `a bootstrap of slash alone adds nothing and still protects the volume root`() {
        for spelling in ["/", "//", "/.", "/..", "/./../"] {
            let roots = FilaGuard.protectedRoots(bootstrapRoot: spelling)
            #expect(roots.count == FilaGuard.protectedRoots(bootstrapRoot: "").count, "\(spelling)")
            #expect(FilaGuard.isDestructionProtected("/", bootstrapRoot: spelling))
        }
    }

    @Test
    func `trash directory names never double their separator`() {
        for base in ["/", "/private/var/jb", "/System/Volumes/Data"] {
            let directory = FilaTrash.directory(under: base)
            #expect(!directory.contains("//"))
            #expect(directory.hasSuffix("/" + FilaTrash.directoryName))
        }
    }
}
