import CoreGraphics
import FilaFormats
@testable import FilaMedia
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

/// Real files and real descriptors, like every other suite here — the point of
/// these generators is that they read through a descriptor, and a fake in front
/// of them would prove nothing about the only thing that can go wrong.
@Suite("Thumbnails")
struct ThumbnailTests {
    @Test
    func `Executable artwork uses content, not filenames or 0777 permissions`() async throws {
        try await withScratchAsync { directory in
            let file = directory.appendingPathComponent("launchd")
            let service = ThumbnailService()
            for (index, bytes) in [Data([0xCF, 0xFA, 0xED, 0xFE]), Data([0xCA, 0xFE, 0xBA, 0xBF]), Data("text".utf8)].enumerated() {
                try bytes.write(to: file)
                #expect(chmod(file.path, 0o777) == 0)
                let found = await service.isMachO(path: file.path, modified: Double(index), byteCount: 4) { try openForReading(file) }
                #expect(found == (index < 2))
                let cached = await service.isMachO(path: file.path, modified: Double(index), byteCount: 4) { throw POSIXError(.EACCES) }
                #expect(cached == found)
            }
        }
    }

    @Test
    func `Image metadata reports dimensions without making a thumbnail`() async throws {
        try await withScratchAsync { directory in
            let file = directory.appendingPathComponent("wide.png")
            try writePNG(width: 900, height: 300, to: file)
            let descriptor = try openForReading(file)
            defer { close(descriptor) }
            let info = try await FileMediaInformation.read(descriptor: descriptor, name: file.lastPathComponent)
            #expect(info.width == 900)
            #expect(info.height == 300)
            #expect(info.duration == nil)
        }
    }

    @Test
    func `Background thumbnails do not promote a named image into PDF decoding`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("wallpaper.png")
            try writePDF(to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let image = await service.thumbnail(path: url.path, modified: 1, byteCount: size,
                                                open: { try openForReading(url) })
            #expect(image == nil)
            let pdf = await service.thumbnail(path: directory.appendingPathComponent("wallpaper.pdf").path,
                                              modified: 1, byteCount: size,
                                              open: { try openForReading(url) })
            #expect(pdf != nil)
        }
    }

    @Test
    func `Full image previews downsample an ordinary large image before display`() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("wide-preview.png")
            try writePNG(width: 8192, height: 64, to: url)
            let image = try #require(ImagePreview.make(data: Data(contentsOf: url)))
            #expect(image.width == 4096)
            #expect(image.height == 32)
        }
    }

    /// A panorama over the pixel ceiling is not a broken file, and the viewer
    /// must be able to say which one it has.
    @Test
    func `An image over the pixel ceiling says it is too large, not unsupported`() throws {
        try withScratch { directory in
            // One pixel wider than the ceiling allows, and two rows tall, so
            // the fixture itself costs nothing to draw.
            let url = directory.appendingPathComponent("panorama.png")
            try writePNG(width: 32769, height: 2, to: url)
            let data = try Data(contentsOf: url)
            #expect(throws: ImagePreview.TooLarge(width: 32769, height: 2)) {
                try ImagePreview.decode(data: data)
            }
            #expect(ImagePreview.make(data: data) == nil)
        }
        #expect(try ImagePreview.decode(data: Data("not a picture".utf8)) == nil)
        let message = try #require(ImagePreview.TooLarge(width: 32769, height: 2).errorDescription)
        #expect(message.contains("too large to preview"), "\(message)")
    }

    @Test
    func `An image thumbnail comes back inside the pixel bound`() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("wide.png")
            try writePNG(width: 900, height: 300, to: url)
            try withDescriptor(reading: url) { descriptor in
                let size = try byteCount(of: url)
                let image = try DescriptorImage.thumbnail(descriptor: descriptor, byteCount: size, maxPixelSize: 64)
                let thumbnail = try #require(image)
                #expect(max(thumbnail.width, thumbnail.height) == 64)
                // Aspect kept: 900x300 is 3:1, so the short edge lands on 21.
                #expect(thumbnail.height < thumbnail.width)
            }
        }
    }

    @Test
    func `The provider outlives the caller's descriptor, because it dups`() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("closed.png")
            try writePNG(width: 200, height: 200, to: url)
            let size = try byteCount(of: url)
            let descriptor = try openForReading(url)
            let image = try DescriptorImage.thumbnail(descriptor: descriptor, byteCount: size, maxPixelSize: 32)
            // Closing here is what a caller does the moment generation returns;
            // a borrowed descriptor would make the next read a wrong picture.
            close(descriptor)
            #expect(image != nil)
        }
    }

    @Test
    func `A PDF's first page renders, on white rather than on nothing`() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("one.pdf")
            try writePDF(to: url)
            try withDescriptor(reading: url) { descriptor in
                let size = try byteCount(of: url)
                let page = try DescriptorImage.firstPage(descriptor: descriptor, byteCount: size, maxPixelSize: 48)
                let image = try #require(page)
                #expect(max(image.width, image.height) == 48)
            }
        }
    }

    @Test
    func `Something that is not a picture fails to nil rather than to an error`() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("notes.txt")
            try Data("just words".utf8).write(to: url)
            try withDescriptor(reading: url) { descriptor in
                let image = try DescriptorImage.thumbnail(descriptor: descriptor, byteCount: 10, maxPixelSize: 64)
                #expect(image == nil)
            }
        }
    }

    @Test
    func `The service caches on path, time and size together`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("cached.png")
            try writePNG(width: 120, height: 120, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()

            let opens = Counter()
            func generate(modified: Double) async -> CGImage? {
                await service.thumbnail(
                    path: url.path,
                    modified: modified,
                    byteCount: size,
                    maxPixelSize: 32,
                    open: { await opens.bump(); return try openForReading(url) },
                )
            }

            #expect(await generate(modified: 1) != nil)
            #expect(await generate(modified: 1) != nil)
            #expect(await opens.value == 1, "the second call must not reach the file at all")

            // The same file edited in place: a new time, so a new picture.
            #expect(await generate(modified: 2) != nil)
            #expect(await opens.value == 2)
        }
    }

    @Test
    func `A rotated page is drawn upright, not on its side`() throws {
        try withScratch { directory in
            let upright = directory.appendingPathComponent("upright.pdf")
            let sideways = directory.appendingPathComponent("sideways.pdf")
            try writePDF(to: upright, rotate: 0)
            try writePDF(to: sideways, rotate: 90)

            func render(_ url: URL) throws -> (width: Int, height: Int) {
                try withDescriptor(reading: url) { descriptor in
                    let image = try #require(try DescriptorImage.firstPage(
                        descriptor: descriptor,
                        byteCount: byteCount(of: url),
                        maxPixelSize: 64,
                    ))
                    return (image.width, image.height)
                }
            }

            // The page is 200x100. Upright that is landscape; rotated a quarter
            // turn it is portrait, and a thumbnail that ignored `/Rotate` would
            // come back landscape both times.
            let flat = try render(upright)
            #expect(flat.width > flat.height)
            let turned = try render(sideways)
            #expect(turned.height > turned.width)
        }
    }

    @Test
    func `A daemon that has not started yet is not remembered as a failure`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("later.png")
            try writePNG(width: 120, height: 120, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let attempts = Counter()

            struct NotUpYet: Error {}
            // `filad` is on-demand: the first look-up after a respring misses,
            // and the file is perfectly thumbnail-able a moment later.
            let refused = await service.thumbnail(
                path: url.path,
                modified: 1,
                byteCount: size,
                open: { await attempts.bump(); throw NotUpYet() },
            )
            #expect(refused == nil)

            let second = await service.thumbnail(
                path: url.path,
                modified: 1,
                byteCount: size,
                open: { await attempts.bump(); return try openForReading(url) },
            )
            #expect(second != nil, "the refusal must not have been cached")
            #expect(await attempts.value == 2)
        }
    }

    /// A `dup` or a read that fails is the process having a bad moment — at
    /// its descriptor limit, say — and says nothing about the file.
    @Test
    func `A failed read is not remembered as a file with no picture`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("busy.png")
            try writePNG(width: 120, height: 120, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            // Write-only: `fstat` answers and every read fails.
            let failed = await service.thumbnail(path: url.path, modified: 1, byteCount: size, open: { try openForWriting(url) })
            #expect(failed == nil)
            let second = await service.thumbnail(path: url.path, modified: 1, byteCount: size, open: { try openForReading(url) })
            #expect(second != nil, "the failed read must not have been cached")
        }
    }

    @Test
    func `A provider whose reads fail throws rather than drawing nothing`() throws {
        try withScratch { directory in
            let picture = directory.appendingPathComponent("busy.png")
            let document = directory.appendingPathComponent("busy.pdf")
            try writePNG(width: 120, height: 120, to: picture)
            try writePDF(to: document)
            let pictureDescriptor = try openForWriting(picture)
            defer { close(pictureDescriptor) }
            let documentDescriptor = try openForWriting(document)
            defer { close(documentDescriptor) }
            #expect(throws: POSIXError.self) {
                try DescriptorImage.thumbnail(descriptor: pictureDescriptor, byteCount: byteCount(of: picture), maxPixelSize: 32)
            }
            #expect(throws: POSIXError.self) {
                try DescriptorImage.firstPage(descriptor: documentDescriptor, byteCount: byteCount(of: document), maxPixelSize: 32)
            }
        }
    }

    /// Core Graphics decodes a page's images at their declared size before it
    /// scales them, so a few megabytes of Flate can declare gigabytes. The
    /// fixture's image declares 81 megapixels and carries almost no bytes.
    @Test(arguments: [(false, false), (true, false), (false, true)])
    func `A page whose images declare too much raster is not drawn`(throughForm: Bool, inherited: Bool) throws {
        try withScratch { directory in
            func render(width: Int, height: Int) throws -> CGImage? {
                let url = directory.appendingPathComponent("page-\(width).pdf")
                try writeImagePDF(to: url, width: width, height: height, throughForm: throughForm, inherited: inherited)
                return try withDescriptor(reading: url) { descriptor in
                    try DescriptorImage.firstPage(descriptor: descriptor, byteCount: byteCount(of: url), maxPixelSize: 64)
                }
            }
            let small = try render(width: 64, height: 64)
            let declared = try render(width: 9000, height: 9000)
            #expect(small != nil)
            #expect(declared == nil)
        }
    }

    @Test
    func `A file that produces nothing is not re-opened on every pass`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("notes.txt")
            try Data("just words".utf8).write(to: url)
            let service = ThumbnailService()
            let opens = Counter()
            for _ in 0 ..< 3 {
                let image = await service.thumbnail(
                    path: url.path,
                    modified: 1,
                    byteCount: 10,
                    open: { await opens.bump(); return try openForReading(url) },
                )
                #expect(image == nil)
            }
            #expect(await opens.value == 1)
        }
    }

    /// QuickLook answers an unreadable text file with a blank page, not a
    /// failure, so the service must not ask it by path. Root reads everything.
    @Test(.enabled(if: getuid() != 0))
    func `QuickLook is never asked for a path this process cannot read`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("private.txt")
            try Data("root only".utf8).write(to: url)
            let service = ThumbnailService()
            #expect(chmod(url.path, 0) == 0)
            let refused = await service.quickLookThumbnail(
                path: url.path, modified: 1, byteCount: 9,
                workspace: { directory }, open: { try openForReading(url) },
            )
            #expect(refused == nil)
            // The refusal is not remembered: a chmod leaves the key unchanged.
            #expect(chmod(url.path, 0o644) == 0)
            let page = await service.quickLookThumbnail(
                path: url.path, modified: 1, byteCount: 9,
                workspace: { throw OpenFailed(path: "readable", code: 0) }, open: { throw OpenFailed(path: "readable", code: 0) },
            )
            #expect(page != nil, "a readable path goes to QuickLook as it is, with nothing staged")
        }
    }

    /// The daemon's descriptor stands in for the path: the copy QuickLook
    /// reads is made through it, and is gone again once the page is drawn.
    @Test(.enabled(if: getuid() != 0))
    func `An unreadable file is staged through its descriptor and the copy removed`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("private.txt")
            try Data("root only\nsecond line".utf8).write(to: url)
            let size = try byteCount(of: url)
            // Opened while readable, the way the daemon opens it as root.
            let descriptor = try openForReading(url)
            defer { close(descriptor) }
            #expect(chmod(url.path, 0) == 0)
            let workspace = directory.appendingPathComponent("stage")
            let page = await ThumbnailService().quickLookThumbnail(
                path: url.path, modified: 1, byteCount: size, square: true,
                workspace: {
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
                    return workspace
                },
                open: { dup(descriptor) },
            )
            let image = try #require(page)
            #expect(image.width == image.height)
            #expect(!FileManager.default.fileExists(atPath: workspace.path))
        }
    }

    @Test
    func `A cell's thumbnail is square; a preview's is whole`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("wide.png")
            try writePNG(width: 900, height: 300, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let square = try #require(await service.thumbnail(
                path: url.path, modified: 1, byteCount: size, maxPixelSize: 90, square: true,
                open: { try openForReading(url) },
            ))
            #expect(square.width == square.height)
            let whole = try #require(await service.thumbnail(
                path: url.path, modified: 1, byteCount: size, maxPixelSize: 90,
                open: { try openForReading(url) },
            ))
            #expect(whole.width == 90)
            #expect(whole.height == 30)
        }
    }

    @Test
    func `A cancelled row opens nothing`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("scrolled.png")
            try writePNG(width: 120, height: 120, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let opens = Counter()

            let task = Task {
                await service.thumbnail(
                    path: url.path,
                    modified: 1,
                    byteCount: size,
                    open: { await opens.bump(); return try openForReading(url) },
                )
            }
            task.cancel()
            #expect(await task.value == nil)
            #expect(await opens.value == 0)
        }
    }

    @Test
    func `Never more than the bound in flight at once`() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("crowd.png")
            try writePNG(width: 400, height: 400, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let peak = Peak()

            await withTaskGroup(of: Void.self) { group in
                for index in 0 ..< 40 {
                    group.addTask {
                        _ = await service.thumbnail(
                            path: url.path,
                            // A distinct key per task, or the cache answers all
                            // but one and nothing is ever in flight.
                            modified: Double(index),
                            byteCount: size,
                            maxPixelSize: 64,
                            open: {
                                await peak.observe(service.activeCount)
                                return try openForReading(url)
                            },
                        )
                    }
                }
            }
            #expect(await peak.highest <= ThumbnailService.concurrencyLimit)
            #expect(await peak.highest > 0)
        }
    }
}

private actor Counter {
    private(set) var value = 0

    func bump() {
        value += 1
    }
}

private actor Peak {
    private(set) var highest = 0

    func observe(_ count: Int) {
        highest = max(highest, count)
    }
}

// MARK: - Fixtures

private func byteCount(of url: URL) throws -> Int64 {
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    return size?.int64Value ?? 0
}

private func writePNG(width: Int, height: Int, to url: URL) throws {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    )!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil,
    )!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FixtureFailed() }
}

struct FixtureFailed: Error {}

private func openForWriting(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path, O_WRONLY)
    guard descriptor >= 0 else { throw OpenFailed(path: url.path, code: errno) }
    return descriptor
}

/// One page drawing one greyscale image XObject, written by hand so the
/// image can declare a size its bytes do not have. `throughForm` draws it
/// from inside a form XObject; `inherited` puts the resources on the page
/// tree's root rather than on the page.
private func writeImagePDF(to url: URL, width: Int, height: Int, throughForm: Bool, inherited: Bool) throws {
    func stream(_ body: Data, _ dictionary: String) -> Data {
        var data = Data("<< \(dictionary) /Length \(body.count) >>\nstream\n".utf8)
        data.append(body)
        data.append(Data("\nendstream".utf8))
        return data
    }
    let resources = throughForm ? "<< /XObject << /F 5 0 R >> >>" : "<< /XObject << /I 6 0 R >> >>"
    let objects = [
        Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
        Data("<< /Type /Pages /Kids [3 0 R] /Count 1\(inherited ? " /Resources \(resources)" : "") >>".utf8),
        Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100]\(inherited ? "" : " /Resources \(resources)") /Contents 4 0 R >>".utf8),
        stream(Data("q 200 0 0 100 0 0 cm /\(throughForm ? "F" : "I") Do Q".utf8), ""),
        stream(Data("/I Do".utf8), "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /I 6 0 R >> >>"),
        stream(
            Data(repeating: 0x80, count: min(width * height, 4096)),
            "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8",
        ),
    ]
    var pdf = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
        offsets.append(pdf.count)
        pdf.append(Data("\(index + 1) 0 obj\n".utf8))
        pdf.append(object)
        pdf.append(Data("\nendobj\n".utf8))
    }
    let table = pdf.count
    pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
    for offset in offsets {
        pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n".utf8))
    try pdf.write(to: url)
}

private func writePDF(to url: URL, rotate: Int = 0) throws {
    var box = CGRect(x: 0, y: 0, width: 200, height: 100)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 10, y: 10, width: 60, height: 40))
    context.endPDFPage()
    context.closePDF()

    // Core Graphics has no page-dictionary key for `/Rotate`, so the rotation is
    // stamped on afterwards — which is also how a scanner produces one.
    guard rotate != 0 else { return }
    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { throw FixtureFailed() }
    page.rotation = rotate
    guard document.write(to: url) else { throw FixtureFailed() }
}
