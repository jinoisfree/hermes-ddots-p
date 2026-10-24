import AppKit
import ImageIO

final class SpriteAtlas {
    /// The sheet's eleven rows, then the steps of nodding off.
    let counts = [7, 8, 8, 4, 5, 8, 8, 6, 6, 8, 8, PetAnimationTimeline.dozeSteps.count]
    private let rasterizer = PetSpriteRasterizer()
    private var frames: [[NSImage]] = []
    private var presentations: [[PetSpritePresentation]] = []
    private var interactionBounds = CGRect.zero
    private static func sheet(_ name: String, width: Int, height: Int, directory: URL?) -> CGImage? {
        guard let url = directory?.appendingPathComponent(name + ".png") ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Pet"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height else { return nil }
        return image
    }
    init(resourceDirectory: URL? = nil) throws {
        guard let atlas = Self.sheet("spritesheet", width: 1536, height: 2288, directory: resourceDirectory), let wave = Self.sheet("wave", width: 768, height: 208, directory: resourceDirectory),
              let asleep = Self.sheet("doze", width: 768, height: 208, directory: resourceDirectory),
              let approval = Self.sheet("approval-phone", width: 1536, height: 208, directory: resourceDirectory) else {
            throw NSError(domain: "ddots.Sprite", code: 1, userInfo: [NSLocalizedDescriptionKey: "펫 이미지 파일을 읽을 수 없습니다."])
        }
        var metrics: [[SpriteContentMetrics]] = []
        for (row, count) in counts.enumerated() where row < PetAnimationTimeline.dozeRow {
            var images: [NSImage] = [], content: [SpriteContentMetrics] = []
            for column in 0..<count {
                let separate = [PetAnimation.waving.rawValue: wave, PetAnimation.waiting.rawValue: approval][row]
                guard let cell = (separate ?? atlas).cropping(to: CGRect(x: column * 192, y: separate == nil ? row * 208 : 0, width: 192, height: 208)),
                      let measured = SpriteContentMetrics.measure(cell) else {
                    throw NSError(domain: "ddots.Sprite", code: 2, userInfo: [NSLocalizedDescriptionKey: "펫 동작 이미지를 읽을 수 없습니다."])
                }
                images.append(NSImage(cgImage: cell, size: NSSize(width: 192, height: 208)))
                content.append(measured)
            }
            frames.append(images); metrics.append(content)
        }
        // Only the head changes while it dozes: the idle frame, one eye shut, then both and the head nodding.
        let drawings = [frames[0][0]] + (0..<4).compactMap { asleep.cropping(to: CGRect(x: $0 * 192, y: 0, width: 192, height: 208)) }
            .map { NSImage(cgImage: $0, size: NSSize(width: 192, height: 208)) }
        frames.append(PetAnimationTimeline.dozeSteps.map { drawings[$0.image] })
        metrics.append(Array(repeating: metrics[0][0], count: PetAnimationTimeline.dozeSteps.count))
        // The smaller, front-facing look pose from the user's comparison remains unchanged.
        let reference = metrics[10][7]
        interactionBounds = reference.bounds
        if CommandLine.arguments.contains("--ui-smoke") {
            smokeCheck(interactionBounds == PetLayout.visibleSpriteBounds, "Measured sprite bounds match placement bounds")
        }
        for (row, content) in metrics.enumerated() {
            if row == PetAnimation.waving.rawValue || row == PetAnimation.waiting.rawValue {
                // The wave and the phone shake are drawn over the idle pose's cell, so they are shown exactly where and as
                // large as the idle pose.
                presentations.append(Array(repeating: presentations[0][0], count: content.count))
                continue
            }
            presentations.append(content.map { metric in
                PetSpritePresentation.matching((9...10).contains(row) ? metric : content[0], to: reference)
            })
        }
    }
    /// Both views and the comparison harness use this exact drawing path.
    func draw(row: Int, frame: Int, in cell: CGRect, view: NSView? = nil,
              backingScale: CGFloat = 1, mode: PetSpriteRenderMode = .selected) {
        let rect = drawingRect(row: row, frame: frame, in: cell)
        let original = image(row: row, frame: frame)
        if mode == .original {
            original.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        let pixels = view?.convertToBacking(rect) ?? rect.applying(CGAffineTransform(scaleX: backingScale, y: backingScale))
        let aligned = PetSpriteRasterizer.aligned(pixels)
        let destination = view?.convertFromBacking(aligned) ?? aligned.applying(CGAffineTransform(scaleX: 1 / backingScale, y: 1 / backingScale))
        guard let source = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = rasterizer.image(source, row: row, frame: frame % counts[row],
                                            width: Int(aligned.width), height: Int(aligned.height), mode: mode) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: bitmap, size: destination.size).draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
    func opaque(at point: CGPoint, in cell: CGRect, row: Int, frame: Int) -> Bool {
        let rect = drawingRect(row:row,frame:frame,in:cell)
        guard rect.contains(point), let cg = image(row:row,frame:frame).cgImage(forProposedRect:nil,context:nil,hints:nil) else { return false }
        let x = min(cg.width-1,max(0,Int((point.x-rect.minX)/rect.width*CGFloat(cg.width))))
        let y = min(cg.height-1,max(0,Int((rect.maxY-point.y)/rect.height*CGFloat(cg.height))))
        return (NSBitmapImageRep(cgImage:cg).colorAt(x:x,y:y)?.alphaComponent ?? 0) >= 0.25
    }
    func image(row: Int, frame: Int) -> NSImage { frames[row][frame % counts[row]] }
    func drawingRect(row: Int, frame: Int, in cell: CGRect) -> CGRect {
        presentations[row][frame % counts[row]].drawingRect(in: cell)
    }
    func interactionRect(in cell: CGRect) -> CGRect {
        PetSpritePresentation.interactionRect(for: interactionBounds, in: cell)
    }
}
