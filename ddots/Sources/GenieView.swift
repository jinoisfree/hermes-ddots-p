import AppKit

/// Drawing strips in one view also makes the exact distortion available to AppKit smoke captures.
final class GenieView: NSView {
    var image: NSImage?
    var blurredImage: CGImage? { didSet {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bitmap = blurredImage
        softStrips.forEach { $0.contents = bitmap }
        CATransaction.commit()
    } }
    var blurAmount: CGFloat { ChatMorph.genieBlur(progress) }
    var rect = CGRect.zero
    var target = CGPoint.zero
    var progress: CGFloat = 1
    var below = true
    var capturing = false { didSet {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strips.forEach { $0.isHidden = capturing }
        CATransaction.commit()
    } }
    private var strips: [CALayer] = []
    private var softStrips: [CALayer] = []
    func clearStrips() { strips.forEach { $0.removeFromSuperlayer() }; strips = []; softStrips = [] }
    func updateStrips() {
        guard let image else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if strips.count != stripCount {
            clearStrips()
            let bitmap = image.cgImage(forProposedRect:nil,context:nil,hints:nil)
            let softBitmap = blurredImage
            for index in 0..<stripCount {
                let strip = CALayer(); strip.contents = bitmap
                strip.contentsRect = CGRect(x:0,y:CGFloat(index)/CGFloat(stripCount),width:1,height:1/CGFloat(stripCount))
                strip.contentsGravity = .resize
                let soft = CALayer(); soft.contents = softBitmap
                soft.contentsRect = strip.contentsRect; soft.contentsGravity = .resize
                strip.addSublayer(soft); softStrips.append(soft)
                layer?.addSublayer(strip); strips.append(strip)
            }
        }
        for (index,strip) in strips.enumerated() {
            var frame = ChatMorph.genieStrip(rect,target:target,lower:CGFloat(index)/CGFloat(stripCount),upper:CGFloat(index+1)/CGFloat(stripCount),progress:progress,below:below)
            // Cover fractional-pixel seams between adjacent strips, staying inside the original frame.
            if frame.height > 0 { frame.size.height = min(rect.maxY-frame.minY,frame.height+0.5) }
            strip.frame = frame
            softStrips[index].frame = strip.bounds; softStrips[index].opacity = Float(blurAmount)
        }
        CATransaction.commit()
    }
    var stripCount: Int { max(1,Int(ceil(rect.height/ChatMorph.genieStripHeight))) }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard capturing, let image else { return }
        let count = stripCount
        NSGraphicsContext.current?.imageInterpolation = .high
        let soft = blurredImage.map { NSImage(cgImage: $0, size: image.size) }
        for index in 0..<count {
            let low = CGFloat(index)/CGFloat(count), high = CGFloat(index+1)/CGFloat(count)
            var dest = ChatMorph.genieStrip(rect,target:target,lower:low,upper:high,progress:progress,below:below)
            guard dest.width > 0, dest.height > 0 else { continue }
            dest.size.height = min(rect.maxY-dest.minY,dest.height+0.5)
            image.draw(in:dest,from:CGRect(x:0,y:low*image.size.height,width:image.size.width,height:(high-low)*image.size.height),
                       operation:.sourceOver,fraction:1,respectFlipped:false,hints:nil)
            soft?.draw(in:dest,from:CGRect(x:0,y:low*image.size.height,width:image.size.width,height:(high-low)*image.size.height),
                               operation:.sourceOver,fraction:blurAmount,respectFlipped:false,hints:nil)
        }
    }
}
