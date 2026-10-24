import Foundation
import CoreGraphics

/// The message surface is measured in screen points, independently of the sprite scale.
struct PetLayout {
    /// Reference pose in atlas coordinates (top-left origin).
    static let visibleSpriteBounds = CGRect(x: 54, y: 60, width: 118, height: 134)
    /// Placement also keeps the phone and clock, including their faint edges, on screen.
    /// This does not change the body's interaction bounds or its foot anchor.
    static let placementSpriteBounds = CGRect(x: 40, y: 39, width: 146, height: 156)
    private static let heightAboveFoot = visibleSpriteBounds.maxY - placementSpriteBounds.minY
    static let petMargin: CGFloat = 4
    static let headerHeight: CGFloat = 40
    static let perchOverlap = headerHeight / 2
    static let minimumPetScale: CGFloat = 0.25
    static func sprite(foot: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(x: foot.x-visibleSpriteBounds.midX*scale, y: foot.y-14*scale,
               width: 192*scale, height: 208*scale)
    }
    static func resizedSprite(_ cell: CGRect, scale: CGFloat) -> CGRect {
        let visible = visibleSprite(in: cell)
        return sprite(foot: CGPoint(x:visible.midX,y:visible.minY),scale:scale)
    }
    static func maximumHeader(visibleFrame: CGRect, screenFrame: CGRect) -> CGFloat {
        min(visibleFrame.maxY, screenFrame.maxY-heightAboveFoot*minimumPetScale+perchOverlap)
    }
    static func perchScale(userScale: CGFloat, header: CGFloat, screenFrame: CGRect) -> CGFloat {
        max(minimumPetScale, min(userScale, (screenFrame.maxY-header+perchOverlap)/heightAboveFoot))
    }
    static func visibleSprite(in cell: CGRect) -> CGRect {
        spriteBounds(visibleSpriteBounds, in: cell)
    }
    static func placementSprite(in cell: CGRect) -> CGRect {
        spriteBounds(placementSpriteBounds, in: cell)
    }
    private static func spriteBounds(_ bounds: CGRect, in cell: CGRect) -> CGRect {
        return CGRect(x: cell.minX + bounds.minX * cell.width / 192,
                      y: cell.minY + (208 - bounds.maxY) * cell.height / 208,
                      width: bounds.width * cell.width / 192, height: bounds.height * cell.height / 208)
    }
    static func constrainedSprite(_ sprite: CGRect, screen: CGRect, screenFrame: CGRect? = nil) -> CGRect {
        let safe = screen.insetBy(dx: petMargin, dy: petMargin)
        let visible = placementSprite(in: sprite)
        return sprite.offsetBy(
            dx: min(max(visible.minX, safe.minX), max(safe.minX, safe.maxX-visible.width))-visible.minX,
            dy: min(max(visible.minY, safe.minY), max(safe.minY, (screenFrame ?? screen).maxY-visible.height))-visible.minY)
    }
    static let bubbleSize = CGSize(width: 231, height: 56)
    static let expandedSize = CGSize(width: 360, height: 500)
    static let minimumChatSize = CGSize(width: 360, height: 180)
    static let cornerRadius: CGFloat = 20
    static let resizeWidth: CGFloat = 6
    static func preferredSize(width: Double?, height: Double?) -> CGSize {
        guard let width, let height, width.isFinite, height.isFinite,
              (360...16384).contains(width), (Double(minimumChatSize.height)...16384).contains(height) else { return expandedSize }
        return CGSize(width: width, height: height)
    }
    static func maximumChatSize(screen: CGRect, spriteHeight: CGFloat, screenFrame: CGRect? = nil) -> CGSize {
        CGSize(width: max(0, screen.width-24), height: max(0, maximumHeader(visibleFrame:screen,screenFrame:screenFrame ?? screen)-screen.minY-12))
    }
    struct ResizeEdge: OptionSet {
        let rawValue: Int
        static let left = ResizeEdge(rawValue: 1), right = ResizeEdge(rawValue: 2), far = ResizeEdge(rawValue: 4), near = ResizeEdge(rawValue: 8)
    }
    /// Disjoint strips shared by cursor registration and hit testing. The curved part is rounded outward
    /// to one-point rows, so its visible edge is always reachable with the same diagonal cursor.
    static func resizeRegions(bubble r: CGRect, below: Bool) -> [(rect: CGRect, edge: ResizeEdge)] {
        let w = resizeWidth, radius = cornerRadius
        guard r.width >= 2*radius, r.height >= 2*radius else { return [] }
        let sideY = r.minY+radius
        var regions: [(rect: CGRect, edge: ResizeEdge)] = [
            (CGRect(x:r.minX,y:sideY,width:w,height:r.height-2*radius), .left),
            (CGRect(x:r.maxX-w,y:sideY,width:w,height:r.height-2*radius), .right),
            (CGRect(x:r.minX+radius,y:below ? r.minY : r.maxY-w,width:r.width-2*radius,height:w), .far)
        ]
        for offset in stride(from: CGFloat(0), to: radius, by: 1) {
            let inner = radius-10
            let reach = radius-sqrt(max(0, inner*inner-pow(radius-offset, 2)))
            let y = below ? r.minY+offset : r.maxY-offset-1
            regions.append((CGRect(x:r.minX,y:y,width:reach,height:1), [.left,.far]))
            regions.append((CGRect(x:r.maxX-reach,y:y,width:reach,height:1), [.right,.far]))
            let nearY = below ? r.maxY-offset-1 : r.minY+offset
            regions.append((CGRect(x:r.minX,y:nearY,width:reach,height:1), [.left,.near]))
            regions.append((CGRect(x:r.maxX-reach,y:nearY,width:reach,height:1), [.right,.near]))
        }
        return regions
    }
    static func resizeEdge(at point: CGPoint, bubble: CGRect, below: Bool) -> ResizeEdge {
        resizeRegions(bubble: bubble, below: below).first { $0.rect.contains(point) }?.edge ?? []
    }
    /// The page beside the conversation is never dragged narrower than this.
    static let defaultPaneWidth = expandedSize.width * 2
    static let defaultPaneHeight = expandedSize.height * 2
    static func paneHeight(base: CGFloat, open: Bool, saved: CGFloat?) -> CGFloat {
        open ? max(base, saved ?? defaultPaneHeight) : base
    }
    static let minimumPaneWidth: CGFloat = 280
    /// The least a page is worth opening at; with less room than this it goes to the browser instead.
    static let usablePaneWidth: CGFloat = 240
    /// How the width is shared when a page opens beside the conversation. The conversation keeps its width while the
    /// screen has room for both. When it has not, the page takes what is left, and with less than 360pt left
    /// the conversation gives way, down to its own least width.
    static func paneSplit(base: CGFloat, minimumBase: CGFloat, wanted: CGFloat, available: CGFloat) -> (base: CGFloat, pane: CGFloat) {
        let kept = min(base, available)
        guard wanted > 0 else { return (kept, 0) }
        let need = min(wanted, minimumChatSize.width)
        if available - kept >= need { return (kept, min(wanted, available - kept)) }
        let narrowed = max(min(minimumBase, kept), available - need)
        return (narrowed, max(0, available - narrowed))
    }
    /// `trailing` is the width of the page open at the conversation's right; the size returned is the conversation's own.
    static func resized(_ placement: PetPlacement, edge: ResizeEdge, delta: CGPoint, screen: CGRect, trailing: CGFloat = 0, screenFrame: CGRect? = nil) -> CGSize {
        let safe = screen.insetBy(dx: 12, dy: 12), center = placement.bubbleBelow ? visibleSprite(in:placement.globalSprite).midX : placement.globalSprite.midX
        var bubble = placement.globalBubble; bubble.size.width -= trailing
        var width = bubble.width, height = bubble.height
        if edge.contains(.right) {
            let target = min(safe.maxX, bubble.maxX+delta.x)
            if bubble.maxX >= safe.maxX-0.5 && bubble.width > 2*(safe.maxX-center) {
                width += min(0,delta.x)
            } else { width = min(2*(target-center),target-safe.minX) }
        } else if edge.contains(.left) {
            let target = max(safe.minX,bubble.minX+delta.x)
            // Pushed left by the page, the conversation is no longer centred on the pet and its right side stays put.
            if trailing > 0 && bubble.minX < center-bubble.width/2-0.5 { width = bubble.maxX-target }
            else if bubble.minX <= safe.minX+0.5 && bubble.width > 2*(center-safe.minX) {
                width -= max(0,delta.x)
            } else { width = min(2*(center-target),safe.maxX-target) }
        }
        if edge.contains(.far) { height += placement.bubbleBelow ? -delta.y : delta.y }
        if edge.contains(.near) { height += placement.bubbleBelow ? delta.y : -delta.y }
        let availableHeight: CGFloat
        if edge.contains(.near) {
            availableHeight = placement.bubbleBelow ? maximumHeader(visibleFrame:screen,screenFrame:screenFrame ?? screen)-bubble.minY : bubble.maxY-safe.minY-8-placement.globalSprite.height
        } else {
            availableHeight = placement.bubbleBelow ? placement.globalBubble.maxY-safe.minY : safe.maxY-placement.globalSprite.maxY-8
        }
        return CGSize(width: min(safe.width,max(minimumChatSize.width,width)),
                      height: min(max(0,availableHeight),max(minimumChatSize.height,height)))
    }
    /// The conversation's height while the pet is carried with it open underneath: its bottom edge stays at `bottom` and
    /// its top follows the pet's foot, so down makes it shorter and up taller. Held past the top of the screen, the
    /// bottom edge goes down by as much instead, so the pet at the top still makes it taller.
    static func carriedChatHeight(foot: CGFloat, bottom: CGFloat, visibleFrame: CGRect, screenFrame: CGRect) -> CGFloat {
        let safe = visibleFrame.insetBy(dx: 12, dy: 12)
        let wanted = foot + perchOverlap, top = maximumHeader(visibleFrame: visibleFrame, screenFrame: screenFrame)
        let floor = max(safe.minY, bottom - max(0, wanted - top))
        return max(minimumChatSize.height, min(max(wanted, safe.minY), top) - floor)
    }
    /// Moving the pet-facing corner keeps the opposite edge of the conversation in place.
    static func resizedSpriteOrigin(_ placement: PetPlacement, edge: ResizeEdge, size: CGSize) -> CGPoint {
        var origin = placement.anchorOrigin
        if edge.contains(.near) { origin.y += (placement.bubbleBelow ? 1 : -1) * (size.height-placement.globalBubble.height) }
        return origin
    }
    static let actionRowHeight: CGFloat = 34
    static let maximumActions = 3
    /// The bubble only grows downward from its text when it carries action buttons.
    static func bubbleSize(actionCount: Int) -> CGSize {
        actionCount > 0 ? CGSize(width: bubbleSize.width, height: bubbleSize.height + actionRowHeight) : bubbleSize
    }
    /// Button frames in bubble coordinates, measured from the bottom-left corner.
    static func actionRects(count: Int) -> [CGRect] {
        let shown = min(max(count, 0), maximumActions)
        guard shown > 0 else { return [] }
        let inset: CGFloat = 12, gap: CGFloat = 6
        let width = (bubbleSize.width - inset * 2 - gap * CGFloat(shown - 1)) / CGFloat(shown)
        return (0..<shown).map { CGRect(x: inset + CGFloat($0) * (width + gap), y: 9, width: width, height: 24) }
    }
    let scale: CGFloat
    var spriteSize: CGSize { CGSize(width: 192 * scale, height: 208 * scale) }
    var windowSize: CGSize {
        CGSize(width: max(Self.bubbleSize.width, spriteSize.width) + 24,
               height: spriteSize.height + Self.bubbleSize.height + 32)
    }
    var spriteRect: CGRect {
        CGRect(x: (windowSize.width - spriteSize.width) / 2, y: 12,
               width: spriteSize.width, height: spriteSize.height)
    }
    var bubbleRect: CGRect {
        CGRect(x: (windowSize.width - Self.bubbleSize.width) / 2, y: spriteRect.maxY + 8,
               width: Self.bubbleSize.width, height: Self.bubbleSize.height)
    }
}

/// The sprite is the position anchor. The bubble shifts independently to stay on the display.
struct PetPlacement {
    let windowFrame: CGRect
    let spriteRect: CGRect
    let bubbleRect: CGRect
    let bubbleBelow: Bool
    let userScale: CGFloat
    let expanded: Bool
    private let placementScreen: CGRect?
    var effectiveScale: CGFloat { globalSprite.width / 192 }
    var globalSprite: CGRect { spriteRect.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY) }
    var globalBubble: CGRect { bubbleRect.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY) }
    /// A cell origin at the user's scale, keeping the rendered foot in place on save and restore.
    var anchorOrigin: CGPoint { PetLayout.resizedSprite(globalSprite, scale:userScale).origin }

    func dragged(by delta: CGPoint, visibleFrame: CGRect, screenFrame: CGRect? = nil) -> PetPlacement {
        let full = screenFrame ?? visibleFrame
        if expanded && bubbleBelow {
            let maximum = PetLayout.maximumHeader(visibleFrame:visibleFrame,screenFrame:full)
            let height = min(globalBubble.height,max(0,maximum-visibleFrame.minY-12))
            let header = min(max(globalBubble.maxY+delta.y,visibleFrame.minY+12+height),maximum)
            let foot = PetLayout.visibleSprite(in:globalSprite)
            let anchor = PetLayout.sprite(foot:CGPoint(x:foot.midX+delta.x,y:header-PetLayout.perchOverlap),scale:userScale)
            let placed = PetPlacement(spriteOrigin:anchor.origin,scale:userScale,visibleFrame:visibleFrame,
                                      screenFrame:full,expanded:true,preferredSize:CGSize(width:globalBubble.width,height:height),below:true)
            var bubble = placed.globalBubble
            bubble.origin.x = min(max(globalBubble.minX+delta.x,visibleFrame.minX+12),visibleFrame.maxX-12-bubble.width)
            return PetPlacement(globalSprite:placed.globalSprite,globalBubble:bubble,
                                placementScreen:visibleFrame,userScale:userScale,expanded:true)
        }
        let anchor = anchorOrigin
        return PetPlacement(spriteOrigin:CGPoint(x:anchor.x+delta.x,y:anchor.y+delta.y),scale:userScale,
                            visibleFrame:visibleFrame,screenFrame:full,expanded:expanded,
                            preferredSize:globalBubble.size)
    }

    init(globalSprite: CGRect, globalBubble: CGRect, windowFrame: CGRect? = nil, placementScreen: CGRect? = nil,
         userScale: CGFloat? = nil, expanded: Bool = false) {
        self.placementScreen = placementScreen
        self.userScale = userScale ?? globalSprite.width/192
        self.expanded = expanded
        self.windowFrame = windowFrame ?? globalSprite.union(globalBubble).insetBy(dx: -12, dy: -12)
        spriteRect = globalSprite.offsetBy(dx: -self.windowFrame.minX, dy: -self.windowFrame.minY)
        bubbleRect = globalBubble.offsetBy(dx: -self.windowFrame.minX, dy: -self.windowFrame.minY)
        bubbleBelow = globalBubble.midY < globalSprite.midY
    }

    init(spriteOrigin: CGPoint, scale: CGFloat, visibleFrame: CGRect, screenFrame: CGRect? = nil,
         bubbleSize: CGSize = PetLayout.bubbleSize, expanded: Bool = false,
         preferredSize: CGSize = PetLayout.expandedSize, below: Bool? = nil, trailing: CGFloat = 0, expandToFit: Bool = false) {
        let full = screenFrame ?? visibleFrame
        let safe = visibleFrame.insetBy(dx:12,dy:12)
        let requested = CGRect(origin:spriteOrigin,size:PetLayout(scale:scale).spriteSize)
        var sprite = PetLayout.constrainedSprite(requested,screen:visibleFrame,screenFrame:full)
        var size = bubbleSize
        var isBelow: Bool
        if expanded {
            let foot = PetLayout.visibleSprite(in:requested)
            var header = min(max(foot.minY+PetLayout.perchOverlap,safe.minY),
                             PetLayout.maximumHeader(visibleFrame:visibleFrame,screenFrame:full))
            if expandToFit {
                header = max(header, min(safe.minY + preferredSize.height, PetLayout.maximumHeader(visibleFrame: visibleFrame, screenFrame: full)))
            }
            if below == true {
                let minimum = min(preferredSize.height, PetLayout.minimumChatSize.height)
                header = max(header, min(safe.minY+minimum, PetLayout.maximumHeader(visibleFrame:visibleFrame,screenFrame:full)))
            }
            let roomBelow = max(0,header-safe.minY)
            let above = max(0,safe.maxY-sprite.maxY-8)
            isBelow = expandToFit ? true : below ?? (roomBelow >= preferredSize.height || (above < preferredSize.height && roomBelow > above))
            size = CGSize(width:min(preferredSize.width,safe.width),
                          height:min(preferredSize.height,isBelow ? roomBelow : above))
            if isBelow {
                let effective = PetLayout.perchScale(userScale:scale,header:header,screenFrame:full)
                sprite = PetLayout.sprite(foot:CGPoint(x:foot.midX,y:header-PetLayout.perchOverlap),scale:effective)
                sprite = PetLayout.constrainedSprite(sprite,screen:visibleFrame,screenFrame:full)
            }
        } else {
            isBelow = sprite.maxY+8+size.height > safe.maxY
            if isBelow { sprite.origin.y = max(sprite.minY,safe.minY+8+size.height) }
        }
        let extra = expanded ? max(0,min(trailing,safe.width-size.width)) : 0
        let center = expanded && isBelow ? PetLayout.visibleSprite(in:sprite).midX : sprite.midX
        let centered = min(max(center-size.width/2,safe.minX),max(safe.minX,safe.maxX-size.width))
        let top = expanded && isBelow ? PetLayout.visibleSprite(in:sprite).minY+PetLayout.perchOverlap : sprite.minY-8
        let bubble = CGRect(x:max(safe.minX,min(centered,safe.maxX-size.width-extra)),
                            y:isBelow ? top-size.height : sprite.maxY+8,width:size.width+extra,height:size.height)
        self.init(globalSprite:sprite,globalBubble:bubble,placementScreen:visibleFrame,userScale:scale,expanded:expanded)
    }
}

/// Frame-rate independent easing. Keep the bubble inside the current screen even during a transition.
/// How the conversation looks while the bubble grows into it or folds back: it clears as it opens and blurs away as it
/// closes, staying where it is while the glass moves over it.
enum ChatMorph {
    static func genieBlur(_ progress: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        return 1 - p * p * (3 - 2 * p)
    }
    static func genieProgress(from start: CGFloat, opening: Bool, fraction: CGFloat) -> CGFloat {
        let p = min(1, max(0, fraction))
        return opening ? start + (1 - start) * p : start * (1 - p)
    }
    static func perchRect(_ open: CGRect, progress: CGFloat) -> CGRect {
        let p = min(1,max(0,progress))
        let eased = 1-pow(1-p,3)
        let width = max(1,open.width*eased), height = max(1,open.height*eased)
        return CGRect(x:open.midX-width/2,y:open.maxY-height,width:width,height:height)
    }
    static let genieDuration: TimeInterval = 0.30
    static let genieStripHeight: CGFloat = 3
    /// First bend the mouth toward the pet, then pull the body along the funnel.
    static func genieStrip(_ rect: CGRect, target: CGPoint, lower: CGFloat, upper: CGFloat,
                           progress: CGFloat, below: Bool = true) -> CGRect {
        let p = min(1,max(0,progress))
        func smooth(_ x: CGFloat) -> CGFloat { let t = min(1,max(0,x)); return t*t*(3-2*t) }
        let bend = smooth((1-p)/0.42)
        let pull = smooth((1-p-0.32)/0.68)
        let mouth = min(28,rect.width)/rect.width
        func edge(_ u: CGFloat) -> (CGFloat,CGFloat,CGFloat) {
            let near = below ? u : 1-u
            let curve = near*near*(3-2*near)
            let amount = bend*curve
            let width = rect.width*(1-amount*(1-mouth))*(1-pull)
            let center = rect.midX+(target.x-rect.midX)*(amount+(1-amount)*pull)
            let y = (rect.minY+u*rect.height)*(1-pull)+target.y*pull
            return (center,width,y)
        }
        let a=edge(lower), b=edge(upper), m=edge((lower+upper)/2)
        return CGRect(x:m.0-m.1/2,y:a.2,width:m.1,height:max(0,b.2-a.2))
    }
    static let blur: CGFloat = 16
    /// `progress` runs from 0, the folded bubble, to 1, the open conversation.
    static func look(progress: CGFloat) -> (blur: CGFloat, alpha: CGFloat, bubbleAlpha: CGFloat) {
        let p = max(0, min(1, progress))
        // Softest at the start, sharp a little before the window has finished growing.
        let clear = min(1, p / 0.9)
        let radius = blur * (1 - clear) * (1 - clear)
        return (radius < 0.3 ? 0 : radius, min(1, p * 1.5), max(0, 1 - p * 3.2))
    }
    /// How far the glass has grown between the two heights.
    static func progress(height: CGFloat, folded: CGFloat, open: CGFloat) -> CGFloat {
        open > folded ? max(0, min(1, (height - folded) / (open - folded))) : 1
    }
}

enum ChatWidthSlide {
    static let duration: TimeInterval = 0.3
    static let fadeDuration: TimeInterval = 0.06
    static func cover(_ progress: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress / 0.2))
        return p * p * (3 - 2 * p)
    }
}

struct PetBubbleMotion {
    private(set) var position: CGPoint?
    private var target = CGPoint.zero
    private var lastTime: TimeInterval?
    private var bounds = CGRect.zero
    private(set) var size = PetLayout.bubbleSize
    private var targetSize = PetLayout.bubbleSize
    private var widthSlide: (start: TimeInterval, origin: CGPoint, size: CGSize)?
    private(set) var widthProgress: CGFloat = 1
    mutating func slideWidth(now: TimeInterval) {
        widthSlide = (now, position ?? target, size); widthProgress = 0
    }
    mutating func cancelWidthSlide() { widthSlide = nil; widthProgress = 1 }
    private var glideUntil: TimeInterval = 0
    /// Opening and folding the conversation take a little longer than following the pet, so the change can be seen.
    mutating func glide(now: TimeInterval) { glideUntil = now + 0.8 }

    mutating func retarget(_ point: CGPoint, visibleFrame: CGRect, now: TimeInterval, immediately: Bool = false,
                           size: CGSize = PetLayout.bubbleSize, headerAtTop: Bool = false) {
        targetSize = size
        bounds = visibleFrame.insetBy(dx: 12, dy: 12)
        if headerAtTop { bounds.size.height += 12 }
        target = clamped(point, size: targetSize)
        if position == nil || immediately { cancelWidthSlide(); self.size = targetSize; position = target; lastTime = now }
        else if let position { self.position = clamped(position) }
    }

    mutating func step(now: TimeInterval) -> CGPoint {
        if let slide = widthSlide {
            widthProgress = CGFloat(min(1, max(0, (now - slide.start) / ChatWidthSlide.duration)))
            let eased = widthProgress * widthProgress * (3 - 2 * widthProgress)
            size = CGSize(width: slide.size.width + (targetSize.width - slide.size.width) * eased,
                          height: slide.size.height + (targetSize.height - slide.size.height) * eased)
            position = CGPoint(x: slide.origin.x + (target.x - slide.origin.x) * eased,
                               y: slide.origin.y + (target.y - slide.origin.y) * eased)
            lastTime = now
            if widthProgress == 1 { widthSlide = nil; size = targetSize; position = target }
            return position!
        }
        let dt = min(0.1, max(0, now - (lastTime ?? now)))
        lastTime = now
        let previous = position ?? target
        let fraction = 1 - exp(-dt / (now < glideUntil ? 0.105 : 0.065))
        size = CGSize(width: size.width + (targetSize.width - size.width) * fraction,
                      height: size.height + (targetSize.height - size.height) * fraction)
        if abs(size.width - targetSize.width) + abs(size.height - targetSize.height) < 0.2 { size = targetSize }
        let next = CGPoint(x: previous.x + (target.x - previous.x) * fraction,
                           y: previous.y + (target.y - previous.y) * fraction)
        position = hypot(next.x - target.x, next.y - target.y) < 0.2 ? target : clamped(next)
        return position!
    }

    private func clamped(_ point: CGPoint, size requestedSize: CGSize? = nil) -> CGPoint {
        let size = requestedSize ?? self.size
        return CGPoint(x: min(max(point.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                y: min(max(point.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
    }
}

/// One retained closing picture; every presentation input participates in its identity.
struct GeniePictureKey: Equatable {
    var size: CGSize
    var dark: Bool
    var scale: CGFloat
}
