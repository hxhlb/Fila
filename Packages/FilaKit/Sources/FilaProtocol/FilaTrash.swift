/// Where deleted items go, and how they remember where they came from.
///
/// Fila's own directory rather than the system `.Trash/<uid>`: on a jailbroken
/// device nothing else empties, lists or expects that layout, and a name of
/// our own says whose it is. One level, no per-uid split — the daemon and the
/// in-process backend never share a device.
public enum FilaTrash {
    /// Under the bootstrap of a relocated daemon, else under the volume
    /// mount point. Sources may live on a different volume.
    public static let directoryName = ".fila-trash"

    /// Set on a trashed item by the job that renamed it, holding the canonical
    /// path it was renamed away from. Read back by Put Back; removed again once
    /// the item is home. Absent where it could not be set, and then the item
    /// can only be deleted for good or moved out by hand.
    public static let originAttribute = "wiki.qaq.fila.origin"

    /// A batch identity, paired with the origin for Undo even when copying changes the inode.
    public static let jobAttribute = "wiki.qaq.fila.trash-job"

    public static func directory(under base: String) -> String {
        base == "/" ? "/" + directoryName : base + "/" + directoryName
    }

    /// What an item is called in the trash once `suffix` others got there
    /// first under the same name: `name-1`, `name-2`, and so on.
    ///
    /// A name is one path component, 255 bytes at most (`NAME_MAX`), and a
    /// name already that long has no room for `-1`. The stem is shortened on a
    /// scalar boundary instead, so the second long-named item still finds a
    /// free name rather than failing with ENAMETOOLONG. Put Back reads the
    /// origin attribute, never this name, so shortening it loses nothing.
    public static func itemName(_ name: String, suffix: Int) -> String {
        guard suffix > 0 else { return name }
        let tail = "-\(suffix)"
        let budget = 255 - tail.utf8.count
        var stem = String.UnicodeScalarView()
        var length = 0
        for scalar in name.unicodeScalars {
            length += UTF8.width(scalar)
            guard length <= budget else { break }
            stem.append(scalar)
        }
        return String(stem) + tail
    }
}
