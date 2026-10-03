import CoreGraphics
import Foundation

/// Whether drawing a PDF page stays inside the raster budget a picture gets.
///
/// Core Graphics decodes each image a page draws at the size the image
/// declares, before scaling it into the context, so a 512-pixel thumbnail
/// context bounds nothing: Flate packs a flat raster about a thousand to one,
/// and a three-megabyte file can declare a 16000 × 16000 image. The page's
/// resources are walked first — its image XObjects, the forms, tiling
/// patterns and Type 3 fonts that carry resources of their own — and every
/// image's declared size counts against the same 64-megapixel ceiling
/// `ImagePreview` holds one picture to.
///
/// Images drawn inline in a content stream are not walked: finding them means
/// decompressing the content, which is the cost this check exists to avoid.
enum PDFRasterBudget {
    static let pixelCount: Int = 64_000_000
    /// Deeper than any real page nests its forms; a self-referencing form
    /// stops here rather than recursing forever.
    static let maximumDepth = 8
    /// Resource entries visited before the page is refused unread.
    static let maximumEntryCount = 4096
    /// How far up the page tree inherited `/Resources` are looked for.
    static let maximumAncestorCount = 32

    static func fits(_ page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var walk = Walk()
        // `/Resources` is inheritable: a page without its own uses its
        // nearest ancestor's in the page tree.
        var node: CGPDFDictionaryRef? = dictionary
        for _ in 0 ..< maximumAncestorCount {
            guard let current = node else { return true }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                return walk.visit(resources: resources, depth: 0)
            }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        return false
    }

    private struct Walk {
        var remainingPixels = PDFRasterBudget.pixelCount
        var remainingEntries = PDFRasterBudget.maximumEntryCount

        /// False as soon as anything is over budget, too deep or malformed
        /// in a way that would leave the size unknown.
        mutating func visit(resources: CGPDFDictionaryRef, depth: Int) -> Bool {
            guard depth <= PDFRasterBudget.maximumDepth else { return false }
            for category in ["XObject", "Pattern", "Font"] {
                var entries: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(resources, category, &entries), let entries else { continue }
                for object in Self.values(of: entries) {
                    remainingEntries -= 1
                    guard remainingEntries >= 0, visit(object, depth: depth) else { return false }
                }
            }
            return true
        }

        private mutating func visit(_ object: CGPDFObjectRef, depth: Int) -> Bool {
            var stream: CGPDFStreamRef?
            var plain: CGPDFDictionaryRef?
            let dictionary: CGPDFDictionaryRef
            if CGPDFObjectGetValue(object, .stream, &stream), let stream,
               let streamDictionary = CGPDFStreamGetDictionary(stream)
            {
                dictionary = streamDictionary
            } else if CGPDFObjectGetValue(object, .dictionary, &plain), let plain {
                dictionary = plain
            } else {
                return true
            }
            switch Self.name(dictionary, "Subtype") {
            case "Image":
                guard charge(dictionary) else { return false }
                // A soft or explicit mask is a second raster of its own size.
                for key in ["SMask", "Mask"] {
                    var mask: CGPDFStreamRef?
                    if CGPDFDictionaryGetStream(dictionary, key, &mask), let mask,
                       let maskDictionary = CGPDFStreamGetDictionary(mask)
                    {
                        guard charge(maskDictionary) else { return false }
                    }
                }
                return true
            case "Form", "Type3", nil:
                // A form, a Type 3 font, or a tiling pattern (which has no
                // subtype): whatever it draws is in its own resources.
                var resources: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return true }
                return visit(resources: resources, depth: depth + 1)
            default:
                return true
            }
        }

        /// Counts one image's declared raster against the budget.
        private mutating func charge(_ image: CGPDFDictionaryRef) -> Bool {
            var width: CGPDFInteger = 0
            var height: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(image, "Width", &width),
                  CGPDFDictionaryGetInteger(image, "Height", &height),
                  width > 0, height > 0, width <= 32768, height <= 32768,
                  width * height <= remainingPixels
            else { return false }
            remainingPixels -= width * height
            return true
        }

        private static func values(of dictionary: CGPDFDictionaryRef) -> [CGPDFObjectRef] {
            var values: [CGPDFObjectRef] = []
            CGPDFDictionaryApplyBlock(dictionary, { _, value, _ in
                values.append(value)
                return values.count <= PDFRasterBudget.maximumEntryCount
            }, nil)
            return values
        }

        private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var name: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, key, &name), let name else { return nil }
            return String(cString: name)
        }
    }
}
