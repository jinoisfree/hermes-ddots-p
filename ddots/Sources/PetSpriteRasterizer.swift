import AppKit

/// Launch with -petSpriteRendering A, B, C (default), or original; no asset is rewritten.
enum PetSpriteRenderMode: String {
    case original, a = "A", b = "B", c = "C"
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: "petSpriteRendering") ?? "C") ?? .c }
}

/// Owned by SpriteAtlas, used on the main thread. A hard byte/count limit bounds resize churn.
final class PetSpriteRasterizer {
    private struct Key: Hashable { let row: Int; let frame: Int; let width: Int; let height: Int; let mode: String }
    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private(set) var cachedBytes = 0
    var cachedCount: Int { cache.count }
    // Two worst-case 8-frame rows at 200% on 2x: 2 * 8 * 768 * 832 * 4 = 39 MiB.
    static let byteLimit = 48 * 1024 * 1024
    static let countLimit = 128

    static func aligned(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
               width: max(1, rect.width.rounded()), height: max(1, rect.height.rounded()))
    }

    func image(_ source: CGImage, row: Int, frame: Int, width: Int, height: Int, mode: PetSpriteRenderMode) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let key = Key(row: row, frame: frame, width: width, height: height, mode: mode.rawValue)
        if let hit = cache[key] { return hit }
        let scale = min(CGFloat(width) / CGFloat(source.width), CGFloat(height) / CGFloat(source.height))
        let input = (mode == .b || mode == .c) ? Self.strengthened(source, scale: scale) : source
        guard let context = Self.context(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(input, in: CGRect(x: 0, y: 0, width: width, height: height))
        if mode == .c && scale >= 0.6 { PetSpriteContour.apply(source, to: context) }
        guard let result = context.makeImage() else { return nil }
        let bytes = result.bytesPerRow * result.height
        if bytes <= Self.byteLimit {
            while !order.isEmpty && (cachedBytes + bytes > Self.byteLimit || cache.count >= Self.countLimit) {
                let oldest = order.removeFirst()
                if let removed = cache.removeValue(forKey: oldest) { cachedBytes -= removed.bytesPerRow * removed.height }
            }
            cache[key] = result; order.append(key); cachedBytes += bytes
        }
        return result
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    /// Protect all chromatic pixels (including dark brown). Keep alpha exactly unchanged:
    /// darkening is inward only, so neither silhouette nor feature positions move.
    static func strengthened(_ source: CGImage, scale: CGFloat) -> CGImage {
        guard scale < 0.6, scale > 0, let ctx = context(width: source.width, height: source.height) else { return source }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let count = source.width * source.height * 4
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let original = Array(UnsafeBufferPointer(start: data, count: count))
        func channels(_ i: Int) -> (Int, Int, Int) {
            let alpha = max(1, Int(original[i + 3]))
            return (Int(original[i]) * 255 / alpha, Int(original[i + 1]) * 255 / alpha, Int(original[i + 2]) * 255 / alpha)
        }
        var ink = [Bool](repeating: false, count: count / 4)
        for p in ink.indices where original[p * 4 + 3] >= 128 {
            let (r,g,b) = channels(p * 4)
            ink[p] = max(r,g,b) <= 52 && max(r,g,b) - min(r,g,b) <= 14
        }
        // A 2px authored stroke targets ~1.3 output pixels, capped to avoid merging features.
        let radius = min(1.25, max(0, (1.3 / scale - 2) / 2))
        let reach = Int(ceil(radius + 0.5))
        for y in 0..<source.height {
            for x in 0..<source.width {
                let p = y * source.width + x, i = p * 4
                guard original[i + 3] > 0, !ink[p] else { continue }
                let (r,g,b) = channels(i)
                guard max(r,g,b) - min(r,g,b) <= 14 else { continue }
                var coverage: CGFloat = 0
                for dy in -reach...reach {
                    for dx in -reach...reach {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < source.width, ny >= 0, ny < source.height, ink[ny * source.width + nx] else { continue }
                        coverage = max(coverage, min(1, max(0, radius + 0.5 - hypot(CGFloat(dx), CGFloat(dy)))))
                    }
                }
                for c in 0..<3 { data[i+c] = UInt8((CGFloat(original[i+c]) * (1 - coverage) + CGFloat(original[i+3]) * (20.0 / 255) * coverage).rounded()) }
            }
        }
        return ctx.makeImage() ?? source
    }
}
