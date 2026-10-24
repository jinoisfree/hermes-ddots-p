import Foundation
import CoreGraphics

@main
struct PetLayoutTests {
    static func main() {
        // Nontransparent pixels from both new strips occupy x41...185 and y40...195 in the 192×208 cell.
        func actionArtwork(in cell: CGRect) -> CGRect {
            let scale = cell.width / 192
            return CGRect(x: cell.minX + 41 * scale, y: cell.minY + 13 * scale,
                          width: 144 * scale, height: 155 * scale)
        }
        precondition(PetLayout.visibleSpriteBounds == CGRect(x: 54, y: 60, width: 118, height: 134), "Phone and clock do not enlarge the hover or interaction area")
        let key = GeniePictureKey(size: CGSize(width: 360, height: 670), dark: true, scale: 0.59)
        precondition(key == GeniePictureKey(size: key.size, dark: true, scale: 0.59))
        precondition(key != GeniePictureKey(size: CGSize(width: 361, height: 670), dark: true, scale: 0.59))
        precondition(key != GeniePictureKey(size: key.size, dark: false, scale: 0.59))
        precondition(key != GeniePictureKey(size: key.size, dark: true, scale: 1))
        for screen in [CGRect(x: 0, y: 0, width: 1280, height: 800), CGRect(x: -1440, y: 40, width: 1440, height: 860)] {
            for height in [CGFloat(400), 700, 3000] {
                let placement = PetPlacement(spriteOrigin: CGPoint(x: screen.midX, y: screen.minY + 160), scale: 1,
                                             visibleFrame: screen, expanded: true, preferredSize: CGSize(width: 450, height: height), expandToFit: true)
                precondition(screen.contains(placement.globalBubble), "Automatic height remains in this screen")
                precondition(placement.globalBubble.height >= min(height, screen.height - 40), "Automatic expansion uses screen space above low starting pet")
            }
        }
        precondition(PetLayout.defaultPaneHeight == 1000)
        precondition(PetLayout.paneHeight(base: 500, open: true, saved: nil) == 1000)
        precondition(PetLayout.paneHeight(base: 1200, open: true, saved: 700) == 1200)
        precondition(PetLayout.paneHeight(base: 600, open: true, saved: 700) == 700)
        precondition(PetLayout.paneHeight(base: 500, open: false, saved: 900) == 500)
        for height in [CGFloat(800), 1080, 1600] {
            let screen = CGRect(x: 0, y: 0, width: 1920, height: height)
            let anchor = CGPoint(x: 650, y: 400)
            let original = PetPlacement(spriteOrigin: anchor, scale: 1, visibleFrame: screen, expanded: true)
            let tall = PetPlacement(spriteOrigin: original.anchorOrigin, scale: 1, visibleFrame: screen, expanded: true,
                                    preferredSize: CGSize(width: 360, height: PetLayout.defaultPaneHeight), trailing: 720, expandToFit: true)
            precondition(abs(tall.globalBubble.height - min(1000, PetLayout.maximumHeader(visibleFrame: screen, screenFrame: screen) - screen.minY - 12)) < 0.001)
            precondition(screen.contains(tall.globalBubble))
            let restored = PetPlacement(spriteOrigin: original.anchorOrigin, scale: 1, visibleFrame: screen, expanded: true)
            precondition(restored.globalBubble == original.globalBubble && restored.anchorOrigin == original.anchorOrigin)
        }
        let room = CGRect(x:0,y:0,width:1400,height:1100)
        func close(_ a: CGFloat, _ b: CGFloat) { precondition(abs(a-b)<0.001,"\(a) != \(b)") }
        close(ChatWidthSlide.cover(0), 0); close(ChatWidthSlide.cover(0.1), 0.5)
        close(ChatWidthSlide.cover(0.2), 1); close(ChatWidthSlide.cover(1), 1)
        close(ChatWidthSlide.cover(-1), 0); close(ChatWidthSlide.cover(2), 1)
        var previousCover: CGFloat = 0
        for index in 1...1000 {
            let cover = ChatWidthSlide.cover(CGFloat(index) / 1000)
            precondition(cover >= previousCover && cover <= 1 && cover - previousCover < 0.008)
            previousCover = cover
        }
        close(ChatMorph.genieBlur(0), 1); close(ChatMorph.genieBlur(0.5), 0.5); close(ChatMorph.genieBlur(1), 0)
        close(ChatMorph.genieProgress(from: 0.6, opening: false, fraction: 0), 0.6)
        close(ChatMorph.genieProgress(from: 0.6, opening: false, fraction: 1), 0)
        close(ChatMorph.genieProgress(from: 0.6, opening: true, fraction: 1), 1)
        close(PetLayout.defaultPaneWidth, PetLayout.expandedSize.width * 2)
        precondition(PetLayout.paneSplit(base:360,minimumBase:360,wanted:PetLayout.defaultPaneWidth,available:1400) == (360,720))
        precondition(PetLayout.paneSplit(base:360,minimumBase:360,wanted:PetLayout.defaultPaneWidth,available:900) == (360,540))
        precondition(PetLayout.paneSplit(base:428,minimumBase:428,wanted:PetLayout.defaultPaneWidth,available:700) == (428,272))
        var slide = PetBubbleMotion()
        slide.retarget(CGPoint(x: 20, y: 20), visibleFrame: room, now: 0, immediately: true, size: CGSize(width: 360, height: 500))
        slide.slideWidth(now: 0)
        slide.retarget(CGPoint(x: 20, y: 20), visibleFrame: room, now: 0, size: CGSize(width: 720, height: 500))
        _ = slide.step(now: 0.15); close(slide.size.width, 540)
        slide.slideWidth(now: 0.15)
        slide.retarget(CGPoint(x: 20, y: 20), visibleFrame: room, now: 0.15, size: CGSize(width: 360, height: 500))
        _ = slide.step(now: 0.15); close(slide.size.width, 540)
        _ = slide.step(now: 0.30); close(slide.size.width, 450)
        _ = slide.step(now: 0.46); close(slide.size.width, 360)
        slide.slideWidth(now: 1)
        slide.retarget(CGPoint(x: 20, y: 20), visibleFrame: room, now: 1, immediately: true, size: CGSize(width: 720, height: 500))
        close(slide.size.width, 720); close(slide.widthProgress, 1)
        let full = CGRect(x:0,y:0,width:1400,height:1124)
        for scale in [CGFloat(0.25),0.41,1,2] {
            let cell = PetLayout.sprite(foot:CGPoint(x:700,y:750),scale:scale)
            precondition(cell.size == CGSize(width: 192 * scale, height: 208 * scale))
            precondition(PetLayout.constrainedSprite(cell, screen: room, screenFrame: full) == cell, "Placement away from edges keeps the original cell and body size")
            let perched = PetPlacement(spriteOrigin:cell.origin,scale:scale,visibleFrame:room,screenFrame:full,expanded:true)
            precondition(perched.bubbleBelow)
            close(perched.effectiveScale, scale)
            close(PetLayout.visibleSprite(in:perched.globalSprite).minY,perched.globalBubble.maxY-PetLayout.perchOverlap)
            close(PetLayout.visibleSprite(in:perched.globalSprite).midX,perched.globalBubble.midX)
            for newScale in [CGFloat(0.25),0.41,1,2] {
                let changed = PetLayout.resizedSprite(perched.globalSprite,scale:newScale)
                let after = PetPlacement(spriteOrigin:changed.origin,scale:newScale,visibleFrame:room,screenFrame:full,expanded:true,below:true)
                close(after.globalBubble.maxY,perched.globalBubble.maxY)
                close(PetLayout.visibleSprite(in:after.globalSprite).minY,750)
            }
            let high = perched.dragged(by:CGPoint(x:0,y:99999),visibleFrame:room,screenFrame:full)
            close(high.globalBubble.maxY,room.maxY)
            close(high.effectiveScale,min(scale,(full.maxY-room.maxY+PetLayout.perchOverlap)/155))
            precondition(full.contains(actionArtwork(in: high.globalSprite)), "The clock and phone stay visible when a conversation reaches the menu bar")
            let restored = high.dragged(by:CGPoint(x:0,y:-350),visibleFrame:room,screenFrame:full)
            close(restored.effectiveScale,scale)
            let loaded = PetPlacement(spriteOrigin:high.anchorOrigin,scale:scale,visibleFrame:room,screenFrame:full,expanded:true,preferredSize:high.globalBubble.size,below:true)
            close(loaded.globalSprite.minY,high.globalSprite.minY)
            close(loaded.effectiveScale,high.effectiveScale)
            let hiddenMenu = perched.dragged(by:CGPoint(x:0,y:99999),visibleFrame:room,screenFrame:room)
            close(hiddenMenu.effectiveScale,0.25)
            close(PetLayout.placementSprite(in:hiddenMenu.globalSprite).maxY,room.maxY)
            precondition(room.contains(actionArtwork(in: hiddenMenu.globalSprite)), "Hiding the menu bar still reserves clock headroom at the smallest scale")
            let top = PetPlacement(spriteOrigin:CGPoint(x:600,y:99999),scale:scale,visibleFrame:room,screenFrame:full)
            close(PetLayout.placementSprite(in:top.globalSprite).maxY,full.maxY)
            close(top.effectiveScale, scale)
            precondition(full.contains(actionArtwork(in: top.globalSprite)), "A folded pet keeps its chosen size and all artwork at the top edge")
        }
        let morph = CGRect(x:100,y:100,width:400,height:500)
        for progress in [CGFloat(0),0.2,0.5,0.8,1] {
            let r = ChatMorph.perchRect(morph,progress:progress)
            close(r.maxY,morph.maxY); close(r.midX,morph.midX)
            precondition(morph.contains(r))
        }
        for below in [true,false] {
            let aim = CGPoint(x:morph.midX+70,y:below ? morph.maxY : morph.minY)
            for step in 0...100 {
                let progress = CGFloat(step)/100
                var previous: CGFloat? = nil
                for index in 0..<100 {
                    let low = CGFloat(index)/100, high = CGFloat(index+1)/100
                    let strip = ChatMorph.genieStrip(morph,target:aim,lower:low,upper:high,progress:progress,below:below)
                    if step == 100 {
                        close(strip.minX,morph.minX); close(strip.width,morph.width)
                        close(strip.minY,morph.minY+low*morph.height); close(strip.height,morph.height/100)
                    }
                    if step == 0 { close(strip.midX,aim.x); close(strip.minY,aim.y); close(strip.width,0); close(strip.height,0) }
                    precondition(strip.minX >= morph.minX-0.001 && strip.maxX <= morph.maxX+0.001)
                    precondition(strip.minY >= morph.minY-0.001 && strip.maxY <= morph.maxY+0.001)
                    if let previous { precondition(below ? strip.width <= previous+0.001 : strip.width >= previous-0.001) }
                    previous = strip.width
                    let next = ChatMorph.genieStrip(morph,target:aim,lower:low,upper:high,progress:progress+0.000001,below:below)
                    precondition(abs(next.width-strip.width)<0.01 && abs(next.minY-strip.minY)<0.01)
                }
            }
        }
        print("PASS: Genie endpoints, monotone funnel, containment, continuity in both directions")
        print("PASS: perch, fixed foot across scales, header limit, automatic scale/restoration, saved anchor, hidden menu, top 0pt and anchored morph")
        let preferred = CGSize(width:800,height:700)
        let base = PetPlacement(spriteOrigin:CGPoint(x:600,y:30),scale:1,visibleFrame:room,expanded:true)
        let moved = base.dragged(by: CGPoint(x: 40, y: 50), visibleFrame: room)
        precondition(moved.globalSprite == base.globalSprite.offsetBy(dx: 40, dy: 50))
        precondition(moved.globalBubble == base.globalBubble.offsetBy(dx: 40, dy: 50), "Header drag translates both without changing size")
        for delta in [CGPoint(x: -9999, y: -9999), CGPoint(x: 9999, y: 9999)] {
            let edge = base.dragged(by: delta, visibleFrame: room)
            precondition(CGRect(x:12,y:12,width:room.width-24,height:room.height-12).contains(edge.globalBubble), "Conversation stays inside its margin")
            precondition(edge.globalBubble.width == base.globalBubble.width, "Boundary placement retains conversation width")
        }
        let otherScreen = CGRect(x: -900, y: -200, width: 900, height: 650)
        let transferred = base.dragged(by: CGPoint(x: -1200, y: 0), visibleFrame: otherScreen)
        precondition(otherScreen.contains(transferred.globalBubble), "Smaller negative-coordinate screen fits both views")
        precondition(transferred.effectiveScale <= base.userScale, "Destination may choose the roomier side and shrink the pet")
        precondition(transferred.globalBubble.height < base.globalBubble.height, "Only chat shrinks on a smaller display")
        let dragBelow = PetPlacement(spriteOrigin: CGPoint(x: 600, y: 850), scale: 1, visibleFrame: room, expanded: true)
        let belowMoved = dragBelow.dragged(by: CGPoint(x: 20, y: -30), visibleFrame: room)
        precondition(dragBelow.bubbleBelow && belowMoved.bubbleBelow)
        precondition(belowMoved.globalBubble == dragBelow.globalBubble.offsetBy(dx: 20, dy: -30))
        let belowSmall = dragBelow.dragged(by: .zero, visibleFrame: otherScreen)
        precondition(otherScreen.contains(belowSmall.globalBubble) && belowSmall.bubbleBelow)
        let right = PetLayout.resized(base,edge:.right,delta:CGPoint(x:50,y:0),screen:room)
        precondition(right.width == base.globalBubble.width+100, "Centered resize doubles horizontal movement")
        let shrink = PetLayout.resized(base,edge:[.right,.far],delta:CGPoint(x:-1000,y:-1000),screen:room)
        precondition(shrink == PetLayout.minimumChatSize, "Minimum size is 360 by 180")
        let grow = PetLayout.resized(base,edge:[.right,.far],delta:CGPoint(x:9999,y:9999),screen:room)
        let maxSize = PetLayout.maximumChatSize(screen:room,spriteHeight:208)
        precondition(grow.width <= maxSize.width && grow.height <= maxSize.height)
        let resized = PetPlacement(spriteOrigin:base.globalSprite.origin,scale:1,visibleFrame:room,expanded:true,preferredSize:grow,below:false)
        precondition(resized.globalBubble.minY == base.globalBubble.minY, "Above-pet resize anchors its bottom")
        let under = PetPlacement(spriteOrigin:CGPoint(x:600,y:850),scale:1,visibleFrame:room,expanded:true)
        let underSize = PetLayout.resized(under,edge:.far,delta:CGPoint(x:0,y:80),screen:room)
        let underAfter = PetPlacement(spriteOrigin:under.globalSprite.origin,scale:1,visibleFrame:room,expanded:true,preferredSize:underSize,below:true)
        precondition(under.bubbleBelow && under.globalBubble.maxY == underAfter.globalBubble.maxY && underSize.height == under.globalBubble.height-80)
        let pinned = PetPlacement(spriteOrigin:CGPoint(x:12,y:30),scale:1,visibleFrame:room,expanded:true)
        precondition(PetLayout.resized(pinned,edge:.right,delta:CGPoint(x:50,y:0),screen:room).width == pinned.globalBubble.width+50, "At the screen edge only the free side grows")
        let tiny = CGRect(x:0,y:0,width:340,height:520)
        let reduced = PetPlacement(spriteOrigin:.zero,scale:1,visibleFrame:tiny,expanded:true,preferredSize:preferred)
        precondition(reduced.globalBubble.width < 360 && reduced.globalBubble.height < preferred.height)
        let restored = PetPlacement(spriteOrigin:CGPoint(x:600,y:30),scale:1,visibleFrame:room,expanded:true,preferredSize:preferred)
        precondition(restored.globalBubble.size == preferred, "A larger screen restores the untouched preference")
        precondition(PetLayout.preferredSize(width:nil,height:nil) == PetLayout.expandedSize)
        for invalid in [Double.nan, Double.infinity, -1, 0, 20000] {
            precondition(PetLayout.preferredSize(width:invalid,height:500) == PetLayout.expandedSize)
        }
        precondition(PetLayout.preferredSize(width:500,height:100) == PetLayout.expandedSize)
        precondition(PetLayout.preferredSize(width:800,height:700) == preferred)
        precondition(PetLayout.preferredSize(width:360,height:180) == PetLayout.minimumChatSize)
        precondition(PetLayout.preferredSize(width:360,height:179) == PetLayout.expandedSize)
        for y in stride(from: room.minY-500, through: room.maxY-250, by: 20) {
            let pinned = PetPlacement(spriteOrigin:CGPoint(x:600,y:y),scale:1,visibleFrame:room,expanded:true,below:true)
            precondition(pinned.bubbleBelow && pinned.globalBubble.height >= 180)
            close(PetLayout.visibleSprite(in:pinned.globalSprite).minY,pinned.globalBubble.maxY-PetLayout.perchOverlap)
            precondition(pinned.globalBubble.minY >= room.minY+12)
        }
        precondition(PetLayout.resizeEdge(at:CGPoint(x:base.globalBubble.midX,y:base.globalBubble.minY+2),bubble:base.globalBubble,below:false).isEmpty)
        precondition(PetLayout.resizeEdge(at:CGPoint(x:base.globalBubble.maxX-2,y:base.globalBubble.maxY-2),bubble:base.globalBubble,below:false) == [.right,.far])
        for below in [false, true] {
            let r = base.globalBubble
            for inset in [CGFloat(7), 8, 9] {
                let far = below ? r.minY+inset : r.maxY-inset
                precondition(PetLayout.resizeEdge(at: CGPoint(x:r.minX+inset,y:far),bubble:r,below:below) == [.left,.far])
                precondition(PetLayout.resizeEdge(at: CGPoint(x:r.maxX-inset,y:far),bubble:r,below:below) == [.right,.far])
                let near = below ? r.maxY-inset : r.minY+inset
                precondition(PetLayout.resizeEdge(at: CGPoint(x:r.minX+inset,y:near),bubble:r,below:below) == [.left,.near])
                precondition(PetLayout.resizeEdge(at: CGPoint(x:r.maxX-inset,y:near),bubble:r,below:below) == [.right,.near])
            }
            precondition(PetLayout.resizeEdge(at: CGPoint(x:r.midX,y:below ? r.maxY-2 : r.minY+2),bubble:r,below:below).isEmpty, "The near header remains draggable")
            precondition(PetLayout.resizeEdge(at: CGPoint(x:r.midX,y:below ? r.minY+2 : r.maxY-2),bubble:r,below:below) == .far)
            precondition(PetLayout.resizeEdge(at: CGPoint(x:r.minX+2,y:r.midY),bubble:r,below:below) == .left)
            precondition(PetLayout.resizeEdge(at: CGPoint(x:r.maxX-2,y:r.midY),bubble:r,below:below) == .right)
            precondition(PetLayout.resizeEdge(at: CGPoint(x:r.minX+18,y:below ? r.minY+18 : r.maxY-18),bubble:r,below:below).isEmpty)
        }
        for below in [false, true] {
            let r = base.globalBubble, regions = PetLayout.resizeRegions(bubble: base.globalBubble, below: below)
            for (index, region) in regions.enumerated() {
                for other in regions.dropFirst(index+1) {
                    let overlap = region.rect.intersection(other.rect)
                    precondition(overlap.isNull || overlap.width == 0 || overlap.height == 0, "Cursor regions do not overlap")
                }
            }
            for side in [PetLayout.ResizeEdge.left, .right] {
                for (x,y) in [(2.0,10.0),(10,2),(8,8),(3,18),(18,3),(5.9,19.5),(19.5,5.9),(13.5,12.5)] {
                    let point = CGPoint(x:side == .left ? r.minX+x : r.maxX-x,y:below ? r.minY+y : r.maxY-y)
                    precondition(PetLayout.resizeEdge(at:point,bubble:r,below:below) == [side,.far], "The corner cursor and hit area share the outward-rounded arc")
                    let nearPoint = CGPoint(x:point.x,y:r.minY+r.maxY-point.y)
                    precondition(PetLayout.resizeEdge(at:nearPoint,bubble:r,below:below) == [side,.near])
                    precondition(regions.filter { $0.rect.contains(nearPoint) }.count == 1, "Each near sample has one cursor region")
                }
            }
        }
        for below in [false, true] {
            let start = PetPlacement(spriteOrigin:CGPoint(x:600,y:below ? 800 : 200),scale:1,visibleFrame:room,expanded:true,below:below)
            let direction: CGFloat = below ? 1 : -1
            for side in [PetLayout.ResizeEdge.left, .right] {
                let edge: PetLayout.ResizeEdge = [side,.near]
                for change in [CGFloat(-40), 40, -9999, 9999] {
                    let size = PetLayout.resized(start,edge:edge,delta:CGPoint(x:0,y:direction*change),screen:room)
                    let origin = PetLayout.resizedSpriteOrigin(start,edge:edge,size:size)
                    let after = PetPlacement(spriteOrigin:origin,scale:1,visibleFrame:room,expanded:true,preferredSize:size,below:below)
                    let farBefore = below ? start.globalBubble.minY : start.globalBubble.maxY
                    let farAfter = below ? after.globalBubble.minY : after.globalBubble.maxY
                    precondition(abs(farAfter-farBefore) < 0.001, "Near resizing keeps the far edge fixed")
                    precondition(after.anchorOrigin == origin)
                    precondition(origin.y-start.globalSprite.minY == direction*(size.height-start.globalBubble.height))
                    if abs(change) == 40 { precondition(size.height == start.globalBubble.height+change) }
                    if change == -9999 { precondition(size.height == PetLayout.minimumChatSize.height) }
                    if change == 9999 {
                        precondition(below ? abs(PetLayout.placementSprite(in:after.globalSprite).maxY-room.maxY)<0.001 : after.globalSprite.minY == room.minY+12, "Near growth stops with the whole action inside the screen")
                        precondition(room.contains(actionArtwork(in: after.globalSprite)), "Resizing from either near corner keeps the phone and clock visible")
                    }
                    precondition(room.contains(after.globalBubble))
                    precondition(PetLayout.resizedSpriteOrigin(start,edge:[side,.far],size:size) == start.globalSprite.origin)
                }
            }
        }
        print("PASS: near corners above/below, fixed far edge, pet movement, minimum size and screen limits")
        print("PASS: preferred size validation, display caps/restoration, anchored edges, symmetric and one-sided resize")
        let small = PetLayout(scale: 0.5), large = PetLayout(scale: 2)
        precondition(small.bubbleRect.size == large.bubbleRect.size, "캐릭터 배율이 말풍선에 영향을 주면 안 됩니다.")
        precondition(small.bubbleRect.size == CGSize(width: 231, height: 56), "말풍선 기준 크기가 유지되어야 합니다.")
        precondition(large.spriteRect.width == small.spriteRect.width * 4, "캐릭터는 요청한 배율로 바뀌어야 합니다.")
        precondition(PetLayout(scale: 0.25).spriteSize == CGSize(width: 48, height: 52))
        for scale in [0.25, 0.35, 0.5, 0.8, 1.0, 1.35, 2.0] {
            let layout = PetLayout(scale: scale)
            let window = CGRect(origin: .zero, size: layout.windowSize)
            precondition(window.contains(layout.bubbleRect) && window.contains(layout.spriteRect), "크기 변경 후 내용이 잘리면 안 됩니다.")
            precondition(!layout.bubbleRect.intersects(layout.spriteRect), "말풍선과 캐릭터가 겹치면 안 됩니다.")
        }
        for screen in [CGRect(x: 0, y: 30, width: 1440, height: 870),
                       CGRect(x: -1920, y: -250, width: 1920, height: 1050),
                       CGRect(x: 0, y: 0, width: 800, height: 520)] {
            for scale in [0.25, 0.5, 1, 2] {
                for x in [screen.minX - 100, screen.midX, screen.maxX + 100] {
                    for y in [screen.minY - 100, screen.midY, screen.maxY + 100] {
                        let placement = PetPlacement(spriteOrigin: CGPoint(x: x, y: y), scale: scale, visibleFrame: screen)
                        let globalSprite = placement.spriteRect.offsetBy(dx: placement.windowFrame.minX, dy: placement.windowFrame.minY)
                        let globalBubble = placement.bubbleRect.offsetBy(dx: placement.windowFrame.minX, dy: placement.windowFrame.minY)
                        precondition(CGRect(x:screen.minX+3.999,y:screen.minY+3.999,width:screen.width-7.998,height:screen.height-3.998).contains(PetLayout.visibleSprite(in: globalSprite)), "보이는 그림이 화면 안에 유지")
                        precondition(screen.contains(actionArtwork(in: globalSprite)), "The phone and clock remain on screen at every folded edge and scale")
                        precondition(globalSprite.size == PetLayout(scale: scale).spriteSize, "Edge placement moves the folded pet without shrinking it")
                        precondition(!globalSprite.intersects(globalBubble), "말풍선이 펫을 가리지 않음")
                        precondition(globalBubble.size == CGSize(width: 231, height: 56), "가장자리에서도 말풍선 고정 크기")
                    }
                }
            }
        }
        let left = PetPlacement(spriteOrigin: .zero, scale: 0.25, visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        precondition(left.globalBubble.minX == 12, "왼쪽 가장자리에서는 좌측 정렬")
        let top = PetPlacement(spriteOrigin: CGPoint(x: 988, y: 790), scale: 0.25, visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        precondition(top.bubbleBelow && top.globalBubble.maxX == 988, "위쪽 우측에서는 아래 말풍선과 우측 정렬")
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var motion = PetBubbleMotion()
        motion.retarget(CGPoint(x: 12, y: 12), visibleFrame: screen, now: 0)
        motion.retarget(CGPoint(x: 658, y: 732), visibleFrame: screen, now: 0)
        let first = motion.step(now: 1.0 / 30)
        precondition(first.x > 12 && first.x < 658 && first.y > 12 && first.y < 732, "순간 이동하지 않고 양 축에서 보간")
        var previous = first
        for frame in 2...60 {
            let next = motion.step(now: Double(frame) / 30)
            precondition(next.x >= previous.x && next.y >= previous.y, "과도한 튕김 없이 부드럽게 접근")
            precondition(screen.contains(CGRect(origin: next, size: PetLayout.bubbleSize)), "전환 도중 화면 안에 유지")
            previous = next
        }
        precondition(previous == CGPoint(x: 658, y: 732), "목표 위치에 도착")
        motion.retarget(CGPoint(x: -2000, y: -2000), visibleFrame: screen, now: 2)
        let reverse = motion.step(now: 2.03)
        precondition(reverse.x < previous.x && reverse.x > 12 && reverse.y < previous.y && reverse.y > 12, "반대 방향 전환도 보간")
        motion.retarget(CGPoint(x: 100, y: 100), visibleFrame: screen, now: 3, immediately: true)
        precondition(motion.step(now: 3) == CGPoint(x: 100, y: 100), "동작 줄이기에서는 즉시 배치")
        let tall = PetLayout.bubbleSize(actionCount: 2)
        precondition(PetLayout.bubbleSize(actionCount: 0) == PetLayout.bubbleSize && tall == CGSize(width: 231, height: 90), "버튼이 있을 때만 말풍선이 커짐")
        precondition(PetLayout.actionRects(count: 0).isEmpty && PetLayout.actionRects(count: 9).count == PetLayout.maximumActions, "버튼은 최대 세 개")
        for count in 1...3 {
            let rects = PetLayout.actionRects(count: count)
            let area = CGRect(x: 0, y: 0, width: tall.width, height: PetLayout.actionRowHeight)
            precondition(rects.allSatisfy { area.contains($0) }, "버튼은 글자 아래 줄 안에 배치")
            precondition(zip(rects, rects.dropFirst()).allSatisfy { $0.maxX < $1.minX }, "버튼끼리 겹치지 않음")
        }
        for screen in [CGRect(x: 0, y: 30, width: 1440, height: 870), CGRect(x: 0, y: 0, width: 800, height: 520)] {
            for y in [screen.minY - 100, screen.midY, screen.maxY + 100] {
                let placement = PetPlacement(spriteOrigin: CGPoint(x: screen.maxX, y: y), scale: 1, visibleFrame: screen, bubbleSize: tall)
                precondition(screen.insetBy(dx:12,dy:12).contains(placement.globalBubble) && placement.globalBubble.size == tall, "커진 말풍선도 화면 안에 유지")
                precondition(!placement.globalSprite.intersects(placement.globalBubble), "커진 말풍선이 펫을 가리지 않음")
            }
        }
        var tallMotion = PetBubbleMotion()
        tallMotion.retarget(CGPoint(x: 5000, y: 5000), visibleFrame: screen, now: 0, immediately: true, size: tall)
        precondition(screen.contains(CGRect(origin: tallMotion.step(now: 0), size: tall)), "커진 말풍선의 이동 한계")
        for screen in [CGRect(x: 0, y: 30, width: 1440, height: 870),
                       CGRect(x: -1000, y: -400, width: 1000, height: 760),
                       CGRect(x: 0, y: 0, width: 800, height: 520),
                       CGRect(x: 0, y: 0, width: 340, height: 520)] {
            for scale in [0.25, 1, 2] {
                for x in [screen.minX - 100, screen.midX, screen.maxX + 100] {
                    for y in [screen.minY - 100, screen.midY, screen.maxY + 100] {
                        let folded = PetPlacement(spriteOrigin: CGPoint(x: x, y: y), scale: scale, visibleFrame: screen)
                        let expanded = PetPlacement(spriteOrigin: folded.globalSprite.origin, scale: scale,
                                                    visibleFrame: screen, expanded: true)
                        precondition(abs(PetLayout.visibleSprite(in:expanded.globalSprite).midX-PetLayout.visibleSprite(in:folded.globalSprite).midX)<0.001, "펼쳐도 보이는 중심 유지")
                        precondition(screen.contains(expanded.globalBubble), "작은 화면과 모든 가장자리에서 펼침 영역이 화면 안")
                        precondition(screen.contains(actionArtwork(in: expanded.globalSprite)), "Opening at an edge, including on a negative-coordinate screen, keeps all action artwork visible")
                        precondition(expanded.bubbleBelow || !expanded.globalSprite.intersects(expanded.globalBubble), "아래로 펼칠 때만 머리줄에 걸침")
                        precondition(expanded.globalBubble.height > 0 && expanded.globalBubble.height <= 500)
                    }
                }
            }
        }
        let expanded = PetPlacement(spriteOrigin: CGPoint(x: 500, y: 25), scale: 1, visibleFrame: screen, expanded: true)
        precondition(expanded.globalBubble.size == PetLayout.expandedSize && !expanded.bubbleBelow)
        let below = PetPlacement(spriteOrigin: CGPoint(x: 500, y: 570), scale: 1, visibleFrame: screen, expanded: true)
        precondition(below.bubbleBelow && below.globalBubble.height == 500)
        var growth = PetBubbleMotion()
        growth.retarget(CGPoint(x: 350, y: 250), visibleFrame: screen, now: 0)
        growth.retarget(CGPoint(x: 335, y: 250), visibleFrame: screen, now: 0, size: PetLayout.expandedSize)
        let growingOrigin = growth.step(now: 0.03)
        precondition(growth.size.height > 56 && growth.size.height < 500 && growingOrigin.y == 250, "아래쪽 고정 크기 보간")
        for frame in 2...60 { _ = growth.step(now: Double(frame) / 30) }
        precondition(growth.size == PetLayout.expandedSize)
        growth.retarget(CGPoint(x: 350, y: 250), visibleFrame: screen, now: 3, immediately: true)
        precondition(growth.size == PetLayout.bubbleSize, "동작 줄이기는 크기도 즉시 변경")
        var downward = PetBubbleMotion()
        downward.retarget(CGPoint(x: 350, y: 600), visibleFrame: screen, now: 0)
        downward.retarget(CGPoint(x: 335, y: 156), visibleFrame: screen, now: 0, size: PetLayout.expandedSize)
        let downwardOrigin = downward.step(now: 0.03)
        precondition(abs(downwardOrigin.y + downward.size.height - 656) < 0.01, "아래 펼침은 위쪽 고정")
        print("PASS: expanded bounds, small screens, stable pet anchor, size animation, downward anchor, reduced motion")
        print("PASS: action row sizing, button frames, tall bubble placement")
        print("PASS: fixed bubble and sprite-only scaling at 25, 35, 50, 80, 100, 135, 200 percent")
        print("PASS: edge placement, above/below flipping, off-screen recovery, multiple display coordinates")
        print("PASS: phone and clock edge containment, top expansion and resizing, unchanged body bounds, scale and foot anchor")
        // Folding and opening the conversation: it clears as it opens and blurs away as it folds.
        let foldedLook = ChatMorph.look(progress: 0), half = ChatMorph.look(progress: 0.5), openLook = ChatMorph.look(progress: 1)
        precondition(foldedLook.blur == ChatMorph.blur && foldedLook.alpha == 0 && foldedLook.bubbleAlpha == 1, "접힌 말풍선에서는 대화가 보이지 않는다")
        precondition(half.blur > 0 && half.blur < foldedLook.blur && half.alpha > 0.5 && half.bubbleAlpha == 0, "중간에는 흐리게 보이고 말풍선 글은 이미 사라졌다")
        precondition(openLook.blur == 0 && openLook.alpha == 1 && openLook.bubbleAlpha == 0 && ChatMorph.look(progress: 0.93).blur == 0, "다 열리기 조금 전에 또렷해진다")
        precondition(ChatMorph.look(progress: -1).blur == foldedLook.blur && ChatMorph.look(progress: 2).alpha == 1, "범위를 벗어난 값은 양 끝으로 본다")
        precondition(ChatMorph.progress(height: 54, folded: 54, open: 500) == 0 && ChatMorph.progress(height: 500, folded: 54, open: 500) == 1
                     && ChatMorph.progress(height: 277, folded: 54, open: 500) == 0.5 && ChatMorph.progress(height: 10, folded: 54, open: 54) == 1, "유리가 자란 만큼이 진행도다")
        var slowMotion = PetBubbleMotion(), quickMotion = PetBubbleMotion()
        let morphScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for index in 0..<2 {
            var motion = PetBubbleMotion()
            motion.retarget(CGPoint(x: 100, y: 100), visibleFrame: morphScreen, now: 0, immediately: true, size: CGSize(width: 220, height: 54))
            if index == 0 { motion.glide(now: 0) }
            motion.retarget(CGPoint(x: 100, y: 100), visibleFrame: morphScreen, now: 0, size: CGSize(width: 360, height: 500))
            for step in 1...6 { _ = motion.step(now: Double(step) / 60) }
            if index == 0 { slowMotion = motion } else { quickMotion = motion }
        }
        precondition(slowMotion.size.height < quickMotion.size.height && slowMotion.size.height > 54, "대화를 여닫을 때는 조금 더 천천히 자란다")
        for step in 7...120 { _ = slowMotion.step(now: Double(step) / 60) }
        precondition(slowMotion.size == CGSize(width: 360, height: 500), "끝에는 같은 크기에 닿는다")
        // A page beside the conversation.
        let paned = PetPlacement(spriteOrigin:CGPoint(x:600,y:30),scale:1,visibleFrame:room,expanded:true,trailing:360)
        precondition(paned.globalBubble.minX == base.globalBubble.minX && paned.globalBubble.width == base.globalBubble.width+360
                     && paned.globalBubble.height == base.globalBubble.height, "The page grows out to the right and the conversation stays where it is")
        let pushed = PetPlacement(spriteOrigin:CGPoint(x:1100,y:30),scale:1,visibleFrame:room,expanded:true,trailing:360)
        precondition(pushed.globalBubble.maxX == 1388 && pushed.globalBubble.width == 720 && pushed.globalSprite.minX == 1100, "At the screen's end the window moves left and the pet stays")
        let folded = PetPlacement(spriteOrigin:CGPoint(x:600,y:30),scale:1,visibleFrame:room,trailing:360)
        precondition(folded.globalBubble.width == PetLayout.bubbleSize.width, "A folded bubble has no page")
        precondition(PetLayout.paneSplit(base:428,minimumBase:428,wanted:428,available:1376) == (428,428), "With room, the page is as wide as the conversation")
        precondition(PetLayout.paneSplit(base:428,minimumBase:428,wanted:428,available:700) == (428,272), "A conversation at its least width keeps it")
        precondition(PetLayout.paneSplit(base:800,minimumBase:360,wanted:800,available:900) == (540,360), "A wide conversation gives way until the page has 360")
        precondition(PetLayout.paneSplit(base:800,minimumBase:360,wanted:0,available:700) == (700,0), "No page, no change")
        precondition(PetLayout.resized(paned,edge:.far,delta:CGPoint(x:0,y:40),screen:room,trailing:360).width == 360, "The size is the conversation's own")
        precondition(PetLayout.resized(paned,edge:.left,delta:CGPoint(x:-50,y:0),screen:room,trailing:360).width == 460, "Centred on the pet, the left edge still moves both sides")
        precondition(PetLayout.resized(pushed,edge:.left,delta:CGPoint(x:-50,y:0),screen:room,trailing:360).width == 410, "Pushed left by the page, the left edge follows the pointer")
        // Carrying the pet with the conversation under it: the bottom edge stays, the top follows the pet.
        let carryFull = CGRect(x: 0, y: 0, width: 1920, height: 1080), carryVisible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let carryTop = PetLayout.maximumHeader(visibleFrame: carryVisible, screenFrame: carryFull)
        func carried(_ foot: CGFloat, _ bottom: CGFloat) -> CGFloat {
            PetLayout.carriedChatHeight(foot: foot, bottom: bottom, visibleFrame: carryVisible, screenFrame: carryFull)
        }
        let atTop = carryTop - PetLayout.perchOverlap
        precondition(carried(atTop, 81) == carryTop - 81, "At the top, the height reaches from the pet to the kept bottom edge")
        precondition(carried(atTop - 30, 81) == carryTop - 111, "Carried down from the top, the conversation gets shorter at once")
        precondition(carried(atTop + 40, 81) == carryTop - 41, "Held past the top, the conversation grows downward")
        precondition(carried(atTop + 400, 81) == carryTop - 12, "It grows no lower than the screen's bottom margin")
        precondition(carried(200, 81) == PetLayout.minimumChatSize.height, "It shrinks no shorter than the least height")
        print("PASS: smooth two-axis following, reversal, settling, transition bounds, reduced motion, carried height")
    }
}
