import AppKit
import ImageIO

@main
struct SpriteRenderingTests {
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let atlas = try SpriteAtlas(resourceDirectory: resources)
        func pixels(_ image: CGImage) -> [UInt8] {
            let ctx = PetSpriteRasterizer.context(width: image.width, height: image.height)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        var brown = 0, changed = 0
        for row in atlas.counts.indices {
            for frame in 0..<atlas.counts[row] {
                let source = atlas.image(row: row, frame: frame).cgImage(forProposedRect: nil, context: nil, hints: nil)!
                let original = pixels(source), enhanced = pixels(PetSpriteRasterizer.strengthened(source, scale: 0.304))
                precondition(PetSpriteRasterizer.strengthened(source, scale: 0.74) === source, "100% idle: no ink processing")
                for i in stride(from: 0, to: original.count, by: 4) {
                    precondition(original[i+3] == enhanced[i+3], "silhouette alpha unchanged")
                    if original[i+3] >= 128 {
                        let r = Int(original[i]) * 255 / Int(original[i+3]), g = Int(original[i+1]) * 255 / Int(original[i+3]), b = Int(original[i+2]) * 255 / Int(original[i+3])
                        if r - b > 14 && r > g {
                            brown += 1
                            precondition(original[i..<i+4] == enhanced[i..<i+4], "brown pixels remain byte-identical before reduction")
                        }
                    }
                    if original[i..<i+3] != enhanced[i..<i+3] { changed += 1 }
                }
            }
        }
        let source = atlas.image(row: 0, frame: 0).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let rasterizer = PetSpriteRasterizer()
        let first = rasterizer.image(source, row: 0, frame: 0, width: 58, height: 63, mode: .a)!
        precondition(first === rasterizer.image(source, row: 0, frame: 0, width: 58, height: 63, mode: .a), "cache hit")
        for scale in [0.41, 1.0] {
            let rect = atlas.drawingRect(row: 0, frame: 0, in: CGRect(x: 0, y: 0, width: 192 * scale, height: 208 * scale))
            for backing in [1.0, 2.0] {
                let aligned = PetSpriteRasterizer.aligned(rect.applying(CGAffineTransform(scaleX: backing, y: backing)))
                let bitmap = rasterizer.image(source, row: 0, frame: 0, width: Int(aligned.width), height: Int(aligned.height), mode: .a)!
                precondition(CGFloat(bitmap.width) == aligned.width && CGFloat(bitmap.height) == aligned.height)
            }
        }
        for size in 20...220 { _ = rasterizer.image(source, row: 0, frame: 0, width: size, height: size, mode: .a) }
        precondition(rasterizer.cachedCount <= 128 && rasterizer.cachedBytes <= PetSpriteRasterizer.byteLimit)
        let largeA = rasterizer.image(source, row: 0, frame: 0, width: 142, height: 154, mode: .a)!
        let largeB = rasterizer.image(source, row: 0, frame: 0, width: 142, height: 154, mode: .b)!
        precondition(pixels(largeA) == pixels(largeB), "A and B identical at large scale")
        func save(_ image: CGImage, _ name: String) {
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        func current(_ ctx: CGContext, _ body: () -> Void) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            body()
            NSGraphicsContext.restoreGraphicsState()
        }
        // Native size next to nearest-neighbour 6x. All samples call SpriteAtlas.draw.
        for scale in [0.41, 1.0] {
            for dark in [false, true] {
                let sampleW = Int(ceil(192 * scale)) + 8, sampleH = Int(ceil(208 * scale)) + 8
                let columnW = sampleW * 7 + 24, rowH = sampleH * 6 + 38
                let canvas = PetSpriteRasterizer.context(width: columnW * 3, height: rowH * 4 + 40)!
                let background: CGFloat = dark ? 0.12 : 0.95
                canvas.setFillColor(CGColor(gray: background, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
                current(canvas) {
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: dark ? NSColor.white : NSColor.black]
                    for (column, mode) in [PetSpriteRenderMode.original, .a, .b].enumerated() {
                        ("\(mode.rawValue) | petScale \(scale) | 1x + 6x" as NSString).draw(at: CGPoint(x: column * columnW + 10, y: canvas.height - 28), withAttributes: attrs)
                        for (index, pose) in [(0,0), (2,0), (7,0), (11,PetAnimationTimeline.dozeStill)].enumerated() {
                            let sample = PetSpriteRasterizer.context(width: sampleW, height: sampleH)!
                            sample.setFillColor(CGColor(gray: background, alpha: 1)); sample.fill(CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
                            current(sample) { atlas.draw(row: pose.0, frame: pose.1, in: CGRect(x: 4, y: 4, width: 192 * scale, height: 208 * scale), mode: mode) }
                            let bitmap = sample.makeImage()!
                            let x = column * columnW + 8, y = canvas.height - 40 - (index + 1) * rowH
                            ("row \(pose.0), frame \(pose.1)" as NSString).draw(at: CGPoint(x: x, y: y + rowH - 24), withAttributes: attrs)
                            canvas.interpolationQuality = .none
                            canvas.draw(bitmap, in: CGRect(x: x, y: y + 8, width: sampleW, height: sampleH))
                            canvas.draw(bitmap, in: CGRect(x: x + sampleW + 8, y: y + 8, width: sampleW * 6, height: sampleH * 6))
                            save(bitmap, "sample-\(Int(scale*100))-\(dark ? "dark" : "light")-r\(pose.0)-\(mode.rawValue).png")
                        }
                    }
                }
                save(canvas.makeImage()!, "compare-\(Int(scale*100))-\(dark ? "dark" : "light").png")
            }
        }
        try LargeSpriteRenderingTests.run(atlas: atlas, output: output)
        print("PASS: \(brown) brown pixels protected, \(changed) neutral pixels strengthened; alpha unchanged across all frames; A=B at large scale; 1x/2x pixel sizes; cache hit and hard limits (\(rasterizer.cachedBytes) bytes). Four comparison sheets saved.")
    }
}
