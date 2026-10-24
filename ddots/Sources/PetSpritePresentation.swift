import CoreGraphics

struct SpriteContentMetrics {
    /// Coordinates use the atlas's top-left origin, excluding mostly transparent edge pixels.
    let bounds: CGRect
    let opaquePixels: Int

    static func measure(_ image: CGImage) -> SpriteContentMetrics? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        var left = width, top = height, right = 0, bottom = 0, count = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 64 {
                left = min(left, x); top = min(top, y)
                right = max(right, x + 1); bottom = max(bottom, y + 1); count += 1
            }
        }
        guard count > 0 else { return nil }
        return SpriteContentMetrics(bounds: CGRect(x: left, y: top, width: right - left, height: bottom - top), opaquePixels: count)
    }
}

struct PetSpritePresentation {
    let scale: CGFloat
    let offset: CGPoint // Atlas coordinates, top-left origin.
    static let cellSize = CGSize(width: 192, height: 208)

    /// One fixed transform per animated row preserves jumps, breathing and lying down.
    /// Look frames are separate directional poses and use their own transform.
    /// A row given a `scale` is drawn at that size instead of being fitted, standing on the same ground.
    static func matching(_ basis: SpriteContentMetrics, to reference: SpriteContentMetrics, scale fixed: CGFloat? = nil) -> PetSpritePresentation {
        let heightRatio = reference.bounds.height / basis.bounds.height
        let areaRatio = sqrt(CGFloat(reference.opaquePixels) / CGFloat(basis.opaquePixels))
        let scale = fixed ?? min(1, heightRatio, areaRatio)
        return PetSpritePresentation(scale: scale,
                                     offset: CGPoint(x: reference.bounds.midX - basis.bounds.midX * scale,
                                                     y: reference.bounds.maxY - basis.bounds.maxY * scale))
    }

    func drawingRect(in cell: CGRect) -> CGRect {
        let unitX = cell.width / Self.cellSize.width, unitY = cell.height / Self.cellSize.height
        return CGRect(x: cell.minX + offset.x * unitX,
                      y: cell.minY + (Self.cellSize.height * (1 - scale) - offset.y) * unitY,
                      width: cell.width * scale, height: cell.height * scale)
    }

    func contentBounds(_ source: CGRect) -> CGRect {
        CGRect(x: offset.x + source.minX * scale, y: offset.y + source.minY * scale,
               width: source.width * scale, height: source.height * scale)
    }

    static func interactionRect(for reference: CGRect, in cell: CGRect) -> CGRect {
        CGRect(x: cell.minX + reference.minX * cell.width / cellSize.width,
               y: cell.minY + (cellSize.height - reference.maxY) * cell.height / cellSize.height,
               width: reference.width * cell.width / cellSize.width,
               height: reference.height * cell.height / cellSize.height)
    }
}
