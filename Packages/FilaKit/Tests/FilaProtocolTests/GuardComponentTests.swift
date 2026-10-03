import FilaProtocol
import Testing

// A typed or decoded name becomes a path by being joined to a folder, so it
// must be one name. The check is by bytes, because the kernel splits by bytes.

@Suite("One name, never a path")
struct GuardComponentTests {
    @Test(arguments: ["../\u{301}x", "a/\u{301}b", "/\u{301}", "\u{301}/x", "a\u{0}\u{301}", "a/b", "/"])
    func `A separator or a NUL in any spelling is refused`(_ name: String) {
        #expect(!FilaGuard.isComponent(name))
    }

    @Test(arguments: ["", ".", ".."])
    func `Empty, dot and dot-dot are not names`(_ name: String) {
        #expect(!FilaGuard.isComponent(name))
    }

    @Test(arguments: ["a", "café", "e\u{301}", "\u{301}x", "..\u{301}", ".hidden", "...", "a b"])
    func `Ordinary names are names, combining marks included`(_ name: String) {
        #expect(FilaGuard.isComponent(name))
    }
}
