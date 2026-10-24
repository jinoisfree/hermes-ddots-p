import AppKit
import Accelerate

/// Preview C: only the exterior band is replaced, AFTER B has been rasterized.
/// Thus no second resampling can change the face or other pixels inside the band.
enum PetSpriteContour {
    static let supersampling = 4
    static let width: Float = 2 // Measured source stroke medians: 2–3px. Use the thinner end.
    static let sigma: Float = 0.5 // source pixels; smaller than the initial 0.9px experiment
    static let ink: Float = 2 / 255 // median neutral exterior stroke channel in the supplied art

    struct Field {
        let width: Int
        let height: Int
        let alpha: [Float]
        let distance: [Float]
        func sample(_ values: [Float], x: Float, y: Float) -> Float {
            let x = max(0, min(Float(width - 1), x)), y = max(0, min(Float(height - 1), y))
            let ix = Int(x), iy = Int(y), nx = min(width - 1, ix + 1), ny = min(height - 1, iy + 1)
            let fx = x - Float(ix), fy = y - Float(iy)
            return (values[iy * width + ix] * (1-fx) + values[iy * width + nx] * fx) * (1-fy)
                + (values[ny * width + ix] * (1-fx) + values[ny * width + nx] * fx) * fy
        }
    }

    static func field(_ source: CGImage) -> Field? {
        let w = source.width * supersampling, h = source.height * supersampling
        guard let ctx = PetSpriteRasterizer.context(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var alpha = (0..<w*h).map { Float(data[$0 * 4 + 3]) / 255 }
        let radius = Int(ceil(sigma * Float(supersampling) * 3))
        var kernel = (-radius...radius).map { exp(-Float($0*$0) / (2 * pow(sigma * Float(supersampling), 2))) }
        let sum = kernel.reduce(0,+); kernel = kernel.map { $0 / sum }
        var horizontal = [Float](repeating: 0, count: w*h), smooth = horizontal
        let ok = alpha.withUnsafeMutableBytes { src in
            horizontal.withUnsafeMutableBytes { mid in
                smooth.withUnsafeMutableBytes { dst in
                    var a = vImage_Buffer(data: src.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w*4)
                    var b = vImage_Buffer(data: mid.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w*4)
                    var c = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w*4)
                    return kernel.withUnsafeBufferPointer { k in
                        vImageConvolve_PlanarF(&a, &b, nil, 0, 0, k.baseAddress!, 1, UInt32(k.count), 0, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError &&
                        vImageConvolve_PlanarF(&b, &c, nil, 0, 0, k.baseAddress!, UInt32(k.count), 1, 0, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
                    }
                }
            }
        }
        guard ok else { return nil }
        // Chamfer distance to the smoothed half-alpha contour, in quarter-source pixels.
        var d = smooth.map { $0 >= 0.5 ? Float(10000) : 0 }
        let diagonal: Float = sqrt(2)
        for y in 1..<h-1 {
            for x in 1..<w-1 {
                let p = y*w+x
                if d[p] == 0 { continue }
                d[p] = min(d[p], d[p-1]+1, d[p-w]+1, d[p-w-1]+diagonal, d[p-w+1]+diagonal)
            }
        }
        for y in stride(from: h-2, through: 1, by: -1) {
            for x in stride(from: w-2, through: 1, by: -1) {
                let p = y*w+x
                if d[p] == 0 { continue }
                d[p] = min(d[p], d[p+1]+1, d[p+w]+1, d[p+w+1]+diagonal, d[p+w-1]+diagonal)
            }
        }
        return Field(width: w, height: h, alpha: smooth, distance: d)
    }

    static func apply(_ source: CGImage, to target: CGContext) {
        guard let field = field(source) else { return }
        let data = target.data!.assumingMemoryBound(to: UInt8.self)
        let sx = Float(target.width) / Float(source.width), sy = Float(target.height) / Float(source.height)
        let scale = min(sx, sy), aa = 0.5 / scale
        for y in 0..<target.height {
            for x in 0..<target.width {
                let fx = (Float(x)+0.5) / sx * Float(supersampling) - 0.5
                let fy = (Float(y)+0.5) / sy * Float(supersampling) - 0.5
                let distance = max(0, field.sample(field.distance, x: fx, y: fy)-0.5) / Float(supersampling)
                // Critical: untouched interior bytes remain exactly B, including face details.
                guard distance < width + aa else { continue }
                let coverage = max(0, min(1, (width + aa - distance) / (2*aa)))
                let a = field.sample(field.alpha, x: fx, y: fy)
                let half: Float = 0.22 / scale
                let newAlpha = max(0, min(1, (a - 0.5 + half) / (2*half)))
                let i = y * target.bytesPerRow + x * 4
                for c in 0..<3 {
                    data[i+c] = UInt8(max(0,min(255,(Float(data[i+c]) * (1-coverage) + ink * newAlpha * 255 * coverage).rounded())))
                }
                data[i+3] = UInt8(max(0,min(255,(Float(data[i+3]) * (1-coverage) + newAlpha * 255 * coverage).rounded())))
            }
        }
    }
}
