import AppKit
import ImageIO

/// Standalone raster checks use the same Atlas.draw and rasterizer as both app views.
enum LargeSpriteRenderingTests {
    // Source-image coordinates (top-left); eyes/nose/mouth, excluding the head perimeter.
    static let poses: [(Int,Int,CGRect)] = [
        (0,0,CGRect(x: 55,y: 42,width: 40,height: 25)),
        (9,5,CGRect(x: 109,y: 115,width: 29,height: 33)),
        (10,7,CGRect(x: 86,y: 75,width: 30,height: 19)),
        (2,0,CGRect(x: 46,y: 43,width: 45,height: 22)),
        (7,0,CGRect(x: 91,y: 68,width: 40,height: 22)),
        (11,PetAnimationTimeline.dozeStill,CGRect(x: 55,y: 42,width: 40,height: 25))]
    static func bytes(_ image: CGImage) -> [UInt8] {
        // Read the exact final bitmap; avoid any color conversion in the equality check.
        Array(image.dataProvider!.data! as Data)
    }
    static func run(atlas: SpriteAtlas, output: URL) throws {
        let r = PetSpriteRasterizer()
        var times: [Double] = [], largeTimes: [Double] = [], insideCount = 0, faceCount = 0
        var maxDrift: CGFloat = 0
        for (row, frame, face) in poses {
            let source = atlas.image(row: row, frame: frame).cgImage(forProposedRect: nil, context: nil, hints: nil)!
            for scale: CGFloat in [0.304,0.59,0.74,1,1.5,2,4] {
                let w = Int((192*scale).rounded()), h = Int((208*scale).rounded())
                let b = r.image(source,row: row,frame: frame,width:w,height:h,mode:.b)!
                let start = CFAbsoluteTimeGetCurrent()
                let c = r.image(source,row: row,frame: frame,width:w,height:h,mode:.c)!
                let elapsed = (CFAbsoluteTimeGetCurrent()-start)*1000
                if scale >= 0.6 { times.append(elapsed) }
                if scale == 4 { largeTimes.append(elapsed) }
                let bp = bytes(b), cp = bytes(c)
                if scale < 0.6 { precondition(bp == cp, "C=B below 0.6"); continue }
                let field = PetSpriteContour.field(source)!
                let sx = Float(w)/192, sy = Float(h)/208, aa = 0.5/min(sx,sy)
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y*b.bytesPerRow+x*4
                        let fx = (Float(x)+0.5)/sx*4-0.5, fy = (Float(y)+0.5)/sy*4-0.5
                        let d = max(0,field.sample(field.distance,x:fx,y:fy)-0.5)/4
                        if d >= PetSpriteContour.width+aa {
                            precondition(bp[i..<i+4] == cp[i..<i+4], "all pixels inside the band identical")
                            insideCount += 1
                        }
                        if face.contains(CGPoint(x:(CGFloat(x)+0.5)/CGFloat(sx),y:(CGFloat(y)+0.5)/CGFloat(sy))) {
                            precondition(bp[i..<i+4] == cp[i..<i+4], "face pixels identical row \(row) at \(x),\(y)")
                            faceCount += 1
                        }
                    }
                }
                let bb = SpriteContentMetrics.measure(b)!.bounds, cb = SpriteContentMetrics.measure(c)!.bounds
                // Output quantization costs up to one device pixel, plus <=1 source pixel.
                for delta in [abs(bb.minX-cb.minX),abs(bb.minY-cb.minY),abs(bb.maxX-cb.maxX),abs(bb.maxY-cb.maxY)] {
                    if scale == 4 { maxDrift = max(maxDrift, delta/scale); precondition(delta <= scale, "4x bounds within one source pixel") }
                    precondition(delta <= scale+1, "silhouette bounds drift <=1 source pixel plus raster rounding")
                }
            }
        }
        var smallFrames = 0
        for row in atlas.counts.indices { for frame in 0..<atlas.counts[row] {
            let source = atlas.image(row:row,frame:frame).cgImage(forProposedRect:nil,context:nil,hints:nil)!
            let b = r.image(source,row:row,frame:frame,width:58,height:63,mode:.b)!
            let c = r.image(source,row:row,frame:frame,width:58,height:63,mode:.c)!
            precondition(bytes(b) == bytes(c), "all animation frames C=B at small scale, including wave/doze")
            smallFrames += 1
            let largeB = r.image(source,row:row,frame:frame,width:384,height:416,mode:.b)!
            let largeC = r.image(source,row:row,frame:frame,width:384,height:416,mode:.c)!
            let bp = bytes(largeB), cp = bytes(largeC), field = PetSpriteContour.field(source)!
            for y in 0..<416 { for x in 0..<384 {
                let d = max(0,field.sample(field.distance,x:Float(x)*2+0.5,y:Float(y)*2+0.5)-0.5)/4
                if d >= PetSpriteContour.width+0.25 {
                    let i = y*largeB.bytesPerRow+x*4
                    precondition(bp[i..<i+4] == cp[i..<i+4], "every animation frame interior unchanged, including wave/doze")
                    insideCount += 1
                }
            }}
        }}
        // Worst-case row: raw 192x208 at 200% on 2x (768x832), plus another row.
        let cache = PetSpriteRasterizer()
        var retained: [CGImage] = []
        for row in [9,10] {
            for frame in 0..<8 {
                let source = atlas.image(row:row,frame:frame).cgImage(forProposedRect:nil,context:nil,hints:nil)!
                retained.append(cache.image(source,row:row,frame:frame,width:768,height:832,mode:.c)!)
            }
        }
        for row in [9,10] {
            for frame in 0..<8 {
                let source = atlas.image(row:row,frame:frame).cgImage(forProposedRect:nil,context:nil,hints:nil)!
                precondition(retained[(row-9)*8+frame] === cache.image(source,row:row,frame:frame,width:768,height:832,mode:.c), "two largest rows retained without regeneration")
            }
        }
        let summary = "C: interior \(insideCount) and face \(faceCount) pixels identical; C=B below 0.6; bounds maximum \(maxDrift) source px; small frames \(smallFrames); 4x max \(largeTimes.max()!)ms; cold mean \(times.reduce(0,+)/Double(times.count))ms max \(times.max()!)ms; two rows cache \(cache.cachedBytes) bytes / \(PetSpriteRasterizer.byteLimit)."
        print(summary)
        try summary.write(to:output.appendingPathComponent("large-metrics.txt"),atomically:true,encoding:.utf8)
        try comparisons(atlas:atlas,output:output)
    }
    static func comparisons(atlas: SpriteAtlas, output: URL) throws {
        func current(_ context: CGContext, _ body: () -> Void) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            body(); NSGraphicsContext.restoreGraphicsState()
        }
        func save(_ image:CGImage,_ name:String) {
            let dst=CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(dst,image,nil);precondition(CGImageDestinationFinalize(dst))
        }
        func background(_ ctx:CGContext,_ kind:String) {
            let w=ctx.width,h=ctx.height
            if kind != "midtone" {
                ctx.setFillColor(CGColor(gray:kind == "light" ? 0.95:0.12,alpha:1));ctx.fill(CGRect(x:0,y:0,width:w,height:h));return
            }
            // Deterministic softly varying, photograph-like backdrop; no private screenshot/asset.
            let p=ctx.data!.assumingMemoryBound(to:UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let f=Float(x)/Float(w),g=Float(y)/Float(h)
                let v=0.08*sin(f*7+g*4)+0.04*cos(g*12-f*3)
                let i=y*ctx.bytesPerRow+x*4
                for (c,base) in [Float(0.53),0.47,0.39].enumerated() { p[i+c]=UInt8((base+v)*255) };p[i+3]=255
            }}
        }
        // One sheet per pose/size/background keeps native pixels inspectable without a giant canvas.
        for scale:CGFloat in [1,1.5,2] { for kind in ["light","dark","midtone"] {
            for (row,frame,face) in poses {
                let sw=Int(192*scale)+8,sh=Int(208*scale)+8,colW=sw*4+30,height=sh*3+380
                let canvas=PetSpriteRasterizer.context(width:colW*2,height:height)!
                background(canvas,kind)
                current(canvas) {
                    let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:17),.foregroundColor:kind == "dark" ? NSColor.white:NSColor.black]
                    for (column,mode) in [PetSpriteRenderMode.b,.c].enumerated() {
                        let sample=PetSpriteRasterizer.context(width:sw,height:sh)!;background(sample,kind)
                        let cell=CGRect(x:4,y:4,width:192*scale,height:208*scale)
                        current(sample) { atlas.draw(row:row,frame:frame,in:cell,mode:mode) }
                        let image=sample.makeImage()!,x=column*colW+8
                        ("\(mode.rawValue) | \(Int(scale*100))% | row \(row) frame \(frame) | native + 3x" as NSString).draw(at:CGPoint(x:x,y:height-28),withAttributes:attrs)
                        canvas.interpolationQuality = .none
                        canvas.draw(image,in:CGRect(x:x,y:320,width:sw,height:sh))
                        canvas.draw(image,in:CGRect(x:x+sw+8,y:320,width:sw*3,height:sh*3))
                        let rect=PetSpriteRasterizer.aligned(atlas.drawingRect(row:row,frame:frame,in:cell))
                        let crop=CGRect(x:rect.minX+face.minX/192*rect.width,y:CGFloat(sh)-rect.maxY+face.minY/208*rect.height,width:face.width/192*rect.width,height:face.height/208*rect.height).integral
                        if let faceImage=image.cropping(to:crop) {
                            canvas.draw(faceImage,in:CGRect(x:x,y:30,width:faceImage.width*4,height:faceImage.height*4))
                        }
                        ("Face 4x (unchanged pixels)" as NSString).draw(at:CGPoint(x:x,y:8),withAttributes:attrs)
                    }
                }
                save(canvas.makeImage()!,"compare-large-\(Int(scale*100))-\(kind)-r\(row)-f\(frame).png")
            }
        }}
    }
}
