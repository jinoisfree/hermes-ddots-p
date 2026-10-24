import Foundation
import CoreGraphics
import ImageIO

@main
struct SpritePresentationTests {
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let counts = [7, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8]
        let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
        let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var images: [[CGImage]] = [], metrics: [[SpriteContentMetrics]] = []
        for (row, count) in counts.enumerated() {
            let frames = (0..<count).map { atlas.cropping(to: CGRect(x: $0 * 192, y: row * 208, width: 192, height: 208))! }
            images.append(frames); metrics.append(frames.map { SpriteContentMetrics.measure($0)! })
        }
        let reference = metrics[10][7]
        precondition(reference.bounds == CGRect(x: 54, y: 60, width: 118, height: 134), "pixel orientation and source reference")
        let referenceTransform = PetSpritePresentation.matching(reference, to: reference)
        precondition(referenceTransform.scale == 1 && referenceTransform.offset == .zero, "smaller reference must remain unchanged")
        // What the app draws: the wave drawn on the idle pose, and nodding off from three frames of the 오류 row.
        let sheetWave = metrics[3][0]
        let waveSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[3]) as CFURL, nil)!
        let waveArt = CGImageSourceCreateImageAtIndex(waveSource, 0, nil)!
        precondition(waveArt.width == 768 && waveArt.height == 208, "four wave frames")
        images[3] = (0..<4).map { waveArt.cropping(to: CGRect(x: $0 * 192, y: 0, width: 192, height: 208))! }
        metrics[3] = images[3].map { SpriteContentMetrics.measure($0)! }
        do {
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[5]) as CFURL, nil)!
            let strip = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(strip.width == 1536 && strip.height == 208, "Eight phone frames at the default cell size")
            images[6] = (0..<8).map { strip.cropping(to: CGRect(x: $0 * 192, y: 0, width: 192, height: 208))! }
            metrics[6] = images[6].map { SpriteContentMetrics.measure($0)! }
            for metric in metrics[6] {
                precondition(metric.bounds == metrics[0][0].bounds, "The phone shake keeps the idle pose's body and size")
            }
        }
        let dozeSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[4]) as CFURL, nil)!
        let asleep = CGImageSourceCreateImageAtIndex(dozeSource, 0, nil)!
        precondition(asleep.width == 768 && asleep.height == 208, "one eye shut, both shut, then the head lower and lowest")
        let dozing = (0..<4).map { asleep.cropping(to: CGRect(x: $0 * 192, y: 0, width: 192, height: 208))! }, dozeBounds = dozing.map { SpriteContentMetrics.measure($0)!.bounds }
        precondition(dozeBounds[0] == metrics[0][0].bounds && dozeBounds[1] == metrics[0][0].bounds, "shutting the eyes changes nothing else of the idle pose")
        for nod in dozeBounds.dropFirst(2) {
            precondition(nod.maxY == dozeBounds[1].maxY && nod.minX == dozeBounds[1].minX && nod.maxX == dozeBounds[1].maxX, "only the head moves; the body keeps its size and place")
        }
        precondition(dozeBounds[2].minY - dozeBounds[1].minY == 3 && dozeBounds[3].minY - dozeBounds[1].minY == 6, "the head nods forward a little, then a little more")
        images.append([images[0][0]] + dozing); metrics.append(Array(repeating: metrics[0][0], count: 5))
        var transforms: [[PetSpritePresentation]] = []
        for (row, content) in metrics.enumerated() {
            if row == 3 || row == 6 {
                transforms.append(Array(repeating: transforms[0][0], count: content.count))
                continue
            }
            transforms.append(content.map { PetSpritePresentation.matching((9...10).contains(row) ? $0 : content[0], to: reference) })
        }
        let idleShown = transforms[0][0].contentBounds(metrics[0][0].bounds)
        let sheetWaveShown = PetSpritePresentation.matching(sheetWave, to: reference).contentBounds(sheetWave.bounds)
        precondition(sheetWaveShown.width > idleShown.width, "the sheet's own wave was drawn wider than the idle pose")
        for (frame, metric) in metrics[3].enumerated() {
            let shown = transforms[3][frame].contentBounds(metric.bounds)
            precondition(transforms[3][frame].scale == transforms[0][0].scale && transforms[3][frame].offset == transforms[0][0].offset, "the wave is shown in the idle pose's own place and size")
            precondition(metric.bounds == metrics[0][0].bounds && shown == idleShown, "the lifted paw stays within the idle pose, so the cat keeps its body and size")
        }
        precondition(transforms[11].allSatisfy { $0.scale == transforms[0][0].scale && $0.offset == transforms[0][0].offset }, "nodding off stays exactly where the idle pose is")
        let smaller = referenceTransform.contentBounds(reference.bounds)
        let formerlyLarge = transforms[9][0].contentBounds(metrics[9][0].bounds)
        precondition(abs(formerlyLarge.height - smaller.height) < 0.01, "reported 34% size jump removed")
        precondition(abs(formerlyLarge.midX - smaller.midX) < 0.01 && abs(formerlyLarge.maxY - smaller.maxY) < 0.01, "reported poses share center and ground")
        var directions: [CGRect] = []
        for row in 9...10 {
            for column in 0..<8 { directions.append(transforms[row][column].contentBounds(metrics[row][column].bounds)) }
        }
        for index in 0..<16 {
            precondition(abs(directions[index].height - directions[(index + 1) % 16].height) < 8, "adjacent look directions no longer jump in height")
        }
        for row in (0..<9).filter({ $0 != 3 && $0 != 6 }) {
            let rest = transforms[row][0].contentBounds(metrics[row][0].bounds)
            precondition(rest.height <= reference.bounds.height + 0.01, "ordinary poses use the smaller size budget")
            precondition(abs(rest.maxY - reference.bounds.maxY) < 0.01 && abs(rest.midX - reference.bounds.midX) < 0.01, "state transition shares baseline")
            precondition(transforms[row].allSatisfy { $0.scale == transforms[row][0].scale && $0.offset == transforms[row][0].offset }, "authored animation never auto-zooms per frame")
        }
        precondition(transforms[6].allSatisfy { $0.scale == transforms[0][0].scale && $0.offset == transforms[0][0].offset }, "The phone shake is shown in the idle pose's own place and size")
        let computer = transforms[8][0].contentBounds(metrics[8][0].bounds)
        precondition(abs(computer.height - idleShown.height) < 0.01, "The reply wait at the computer stands as tall as the idle pose")
        let jumpRest = transforms[4][0].contentBounds(metrics[4][0].bounds)
        let jumpPeak = transforms[4][2].contentBounds(metrics[4][2].bounds)
        precondition(jumpRest.maxY - jumpPeak.maxY > 20, "jump retains vertical lift")
        precondition(transforms[5][7].contentBounds(metrics[5][7].bounds).height < 60, "lying-down action remains lying down")
        for scale in [0.25, 0.54, 1, 2] {
            let cell = CGRect(x: -1200, y: -300, width: 192 * scale, height: 208 * scale)
            let interaction = PetSpritePresentation.interactionRect(for: reference.bounds, in: cell)
            precondition(cell.contains(interaction) && abs(interaction.height - reference.bounds.height * scale) < 0.01, "hover and gaze origin follow corrected visible size")
            precondition(!interaction.contains(CGPoint(x: cell.minX + 1, y: cell.maxY - 1)), "transparent padding no longer triggers hover")
            for (row, frames) in metrics.enumerated() {
                for (column, metric) in frames.enumerated() {
                    let transform = transforms[row][column]
                    let rect = transform.drawingRect(in: cell)
                    precondition(transform.scale <= 1 && transform.scale > 0, "never enlarge a small original frame")
                    precondition(abs(rect.width / rect.height - 192.0 / 208.0) < 0.0001, "uniform aspect ratio")
                    let bounds = transform.contentBounds(metric.bounds)
                    precondition(bounds.minX >= 0 && bounds.maxX <= 192 && bounds.minY >= 0 && bounds.maxY <= 208, "visible pixels stay within cell")
                }
            }
        }

        func canvas(width: Int, height: Int) -> CGContext {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.19, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            return ctx
        }
        func save(_ context: CGContext, _ filename: String) {
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(filename) as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        let comparison = canvas(width: 768, height: 208)
        for (index, pose) in [(9, 0), (10, 7), (9, 0), (10, 7)].enumerated() {
            let cell = CGRect(x: index * 192, y: 0, width: 192, height: 208)
            comparison.draw(images[pose.0][pose.1], in: index < 2 ? cell : transforms[pose.0][pose.1].drawingRect(in: cell))
        }
        save(comparison, "sprite-size-comparison.png")
        let overview = canvas(width: 1536, height: 2496)
        for (row, frames) in images.enumerated() {
            for (column, image) in frames.enumerated() {
                let cell = CGRect(x: column * 192, y: (11 - row) * 208, width: 192, height: 208)
                overview.draw(image, in: transforms[row][column].drawingRect(in: cell))
            }
        }
        save(overview, "sprite-size-overview.png")
        print("PASS: 70 sheet frames, the redrawn wave and nodding off; reference unchanged; 34% jump removed; 16-direction continuity; stable state baselines; jump/lying motion preserved; hover bounds; scale range and clipping")
    }
}
