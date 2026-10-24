import AppKit
import WebKit
import CoreImage

/// Only bitmaps cross the worker queue; live WebKit views stay on the main thread.
final class WebPicture {
    let sharp: CGImage, soft: CGImage
    let size: CGSize
    let made: Double
    init(sharp: CGImage, soft: CGImage, size: CGSize) {
        self.sharp = sharp; self.soft = soft; self.size = size; made = ProcessInfo.processInfo.systemUptime
    }
    var fresh: Bool { ProcessInfo.processInfo.systemUptime - made < 30 }
    private static let queue = DispatchQueue(label: "ddots.page-picture", qos: .utility)
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func soften(_ image: CGImage, size: CGSize, completion: @escaping (WebPicture?) -> Void) {
        queue.async {
            let input = CIImage(cgImage: image)
            let radius = 12 * CGFloat(image.width) / max(1, size.width)
            let output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: input.extent)
            let picture = context.createCGImage(output, from: input.extent).map { WebPicture(sharp: image, soft: $0, size: size) }
            DispatchQueue.main.async { completion(picture) }
        }
    }
}

final class PictureWebView: WKWebView {
    var onActivity: (() -> Void)?
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event); onActivity?() }
    override func magnify(with event: NSEvent) { super.magnify(with: event); onActivity?() }
}

/// The first page paint is uncovered after a bounded wait, without a live layer filter.
final class WebPictureSurface: NSView {
    weak var tab: WebTab?
    private var cover: CALayer?
    private var revision = 0
    private var preview: WebPicture?
    private(set) var revealing = false
    /// Over the page in a view of its own: AppKit orders the layers of subviews, not ones added by hand.
    private let coverHost = PetCoverView()
    private var coverLayer: CALayer {
        coverHost.wantsLayer = true; coverHost.frame = bounds; coverHost.autoresizingMask = [.width, .height]
        if coverHost.superview !== self || subviews.last !== coverHost { addSubview(coverHost, positioned: .above, relativeTo: nil) }
        return coverHost.layer!
    }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        cover?.frame = bounds; CATransaction.commit()
    }
    func install(_ tab: WebTab) {
        guard self.tab !== tab else { return }
        revision += 1; cover?.removeFromSuperlayer(); cover = nil; preview = nil; revealing = false
        subviews.forEach { $0.removeFromSuperview() }
        self.tab?.onPicture = nil; self.tab?.loadedView?.alphaValue = 1
        self.tab = tab
        let page = tab.view
        page.frame = bounds; page.autoresizingMask = [.width, .height]; addSubview(page)
        guard tab.revealPending, !ChatView.reducesMotionForChecks else { page.alphaValue = 1; return }
        tab.revealPending = false; revealing = true
        tab.traceReveal("install preview=\(tab.revealPreview != nil) loading=\(page.isLoading)")
        preview = tab.revealPreview; tab.revealPreview = nil
        if let preview {
            let image = CALayer(); image.contents = preview.soft; image.frame = bounds
            coverLayer.addSublayer(image); cover = image
        }
        let generation = revision
        // Opacity does not prevent WebKit from rendering its snapshot.
        page.alphaValue = 0
        tab.onPicture = { [weak self, weak tab] picture in
            guard let self, self.revision == generation, let tab, self.tab === tab, self.revealing else { return }
            self.reveal(picture, generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.revision == generation, self.revealing else { return }
            self.tab?.traceReveal("reveal limit reached without a picture")
            self.reveal(nil, generation: generation)
        }
        DispatchQueue.main.async { [weak tab] in tab?.schedulePicture(delay: 0) }
    }
    private func reveal(_ picture: WebPicture?, generation: Int) {
        guard revealing else { return }
        tab?.traceReveal("reveal picture=\(picture != nil) preview=\(preview != nil)")
        revealing = false; tab?.onPicture = nil
        let picture = picture ?? preview; preview = nil
        cover?.removeFromSuperlayer(); cover = nil
        let layer = CALayer(); layer.frame = bounds; layer.masksToBounds = true
        if let picture { layer.contents = picture.soft; coverLayer.addSublayer(layer); cover = layer; tab?.revealCount += 1 }
        tab?.loadedView?.alphaValue = 1
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.18
        layer.opacity = 0; layer.add(fade, forKey: "reveal")
        if picture == nil {
            tab?.loadedView?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.06; tab?.loadedView?.animator().alphaValue = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak layer] in
            layer?.removeFromSuperlayer()
            if self?.revision == generation { self?.cover = nil }
        }
    }
    var hasPicture: Bool { cover != nil }
}
