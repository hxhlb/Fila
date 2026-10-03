import Foundation

/// How a text file's bytes became the editor's string, and how a save turns the
/// string back into bytes that differ from the file only where the user typed.
///
/// A file that was not UTF-8 must not become UTF-8 because an editor opened
/// it, and a byte-order mark is part of the file: `String(data:encoding:)`
/// drops a UTF-8 one without a word, so it is taken off here and put back on
/// every save. UTF-16 and UTF-32 are edited as themselves. Anything that would
/// not come back byte for byte opens read-only instead — a one-byte `x` typed
/// into UTF-16 read as Latin-1 shifts every code unit after it.
struct TextEncoding: Equatable {
    var encoding: String.Encoding
    /// The mark the file began with, or empty. Written back in front of the
    /// text, so a save never adds one and never takes one away.
    var byteOrderMark = Data()

    struct Decoded {
        var text: String
        var encoding: TextEncoding
        /// Whether `encoding.encode(text)` gives the bytes back exactly. False
        /// for text shown in an encoding a save could not reproduce.
        var isEditable: Bool
    }

    /// Nil when the text holds a character the encoding has no bytes for —
    /// only possible for Latin-1, where the user can type outside its 256.
    func encode(_ text: String) -> Data? {
        text.data(using: encoding).map { byteOrderMark + $0 }
    }

    /// UTF-32 before UTF-16: `FF FE 00 00` begins both. A candidate that does
    /// not decode gives way to the next.
    private static let marks: [(bytes: [UInt8], encoding: String.Encoding)] = [
        ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
        ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
        ([0xEF, 0xBB, 0xBF], .utf8),
        ([0xFF, 0xFE], .utf16LittleEndian),
        ([0xFE, 0xFF], .utf16BigEndian),
    ]

    /// `allowingTruncation` is for a head read cut at an arbitrary byte: the
    /// cut may split a character, which is not a reason to call the file
    /// something other than what it is.
    static func decode(_ data: Data, allowingTruncation: Bool) -> Decoded {
        for mark in marks where data.starts(with: mark.bytes) {
            let candidate = TextEncoding(encoding: mark.encoding, byteOrderMark: Data(mark.bytes))
            let body = Data(data.dropFirst(mark.bytes.count))
            if let decoded = candidate.decode(body, allowingTruncation: allowingTruncation) {
                return decoded
            }
        }
        if let encoding = utf16WithoutMark(data),
           let decoded = TextEncoding(encoding: encoding).decode(data, allowingTruncation: allowingTruncation)
        {
            return decoded
        }
        if let decoded = TextEncoding(encoding: .utf8).decode(data, allowingTruncation: allowingTruncation) {
            return decoded
        }
        // Latin-1 maps every one of the 256 byte values to a character and back
        // again, so it cannot fail and it cannot lose a byte. A NUL is the one
        // thing Latin-1 text never holds: here it is wide text whose encoding
        // nothing above recognised, and an edit would misalign it.
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        return Decoded(text: text, encoding: TextEncoding(encoding: .isoLatin1), isEditable: !data.contains(0))
    }

    /// The text, if `body` (the bytes after the mark) is in this encoding.
    private func decode(_ body: Data, allowingTruncation: Bool) -> Decoded? {
        switch encoding {
        case .utf8:
            // NUL is valid UTF-8 and almost never in UTF-8 text. Without a
            // mark saying UTF-8, zeros mean wide text too short or too mixed
            // for `utf16WithoutMark` to be sure of — shown, not edited.
            let isEditable = !byteOrderMark.isEmpty || !body.contains(0)
            // The decoder also drops a U+FEFF at the start of the body — a
            // second mark after the first — so the round trip is checked here
            // as it is for the wide encodings.
            if let text = String(data: body, encoding: .utf8) {
                return Decoded(text: text, encoding: self, isEditable: isEditable && Data(text.utf8) == body)
            }
            // A failure at a cut retreats up to three bytes before giving up —
            // otherwise a good file reads as Latin-1 because of where it landed.
            guard allowingTruncation else { return nil }
            for trim in 1 ... 3 where body.count > trim {
                let kept = body.dropLast(trim)
                if let text = String(data: kept, encoding: .utf8) {
                    return Decoded(text: text, encoding: self, isEditable: isEditable && Data(text.utf8) == kept)
                }
            }
            return nil
        default:
            let unit = encoding == .utf32LittleEndian || encoding == .utf32BigEndian ? 4 : 2
            var body = body
            if allowingTruncation {
                body = body.prefix(body.count - body.count % unit)
            }
            guard body.count % unit == 0, let text = String(data: body, encoding: encoding) else { return nil }
            // Decoders repair what they cannot read; a repaired file shown is
            // fine, saved is not.
            return Decoded(text: text, encoding: self, isEditable: text.data(using: encoding) == body)
        }
    }

    /// UTF-16 with no mark, recognised by its zero bytes: text that is mostly
    /// ASCII has a zero in every other byte, high half first or second. Valid
    /// UTF-8 as well — NUL is a legal character — so asked before UTF-8 is.
    private static func utf16WithoutMark(_ data: Data) -> String.Encoding? {
        let sample = data.prefix(4096)
        let pairs = sample.count / 2
        guard pairs >= 2 else { return nil }
        var zerosFirst = 0
        var zerosSecond = 0
        for (offset, byte) in sample.prefix(pairs * 2).enumerated() where byte == 0 {
            if offset % 2 == 0 {
                zerosFirst += 1
            } else {
                zerosSecond += 1
            }
        }
        // At least two in five units with a zero half, and the other half
        // almost never zero: binary data has zeros on both sides. A few bytes
        // prove little, so a short file must have a zero in every unit.
        let needed = pairs < 8 ? pairs : (pairs * 2 + 4) / 5
        if zerosSecond >= needed, zerosFirst * 10 < pairs {
            return .utf16LittleEndian
        }
        if zerosFirst >= needed, zerosSecond * 10 < pairs {
            return .utf16BigEndian
        }
        return nil
    }
}
