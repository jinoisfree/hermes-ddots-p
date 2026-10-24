import AppKit
import ImageIO

/// Immutable, decoded thumbnail passed from the monitor queue to the UI. No UI-time file reads.
struct ProfileAvatar: Equatable {
    var image: NSImage?
    /// The decoded thumbnail itself, so the conversation share can encode it without touching AppKit drawing.
    var thumbnail: CGImage?
    var hasProfileColor = false
    var color: NSColor = .systemGray
    static func initial(_ name: String) -> String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)) }
    var foreground: NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        return rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 > 0.55 ? .black : .white
    }
    func draw(in rect: NSRect, name: String, clipPath: CGPath? = nil) {
        NSGraphicsContext.saveGraphicsState()
        let corner = min(rect.width, rect.height) * ChatMetrics.avatarCorner
        if let clipPath, let context = NSGraphicsContext.current?.cgContext {
            context.addPath(clipPath); context.clip()
        } else {
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
        }
        if let image {
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: rect.midX-size.width/2, y: rect.midY-size.height/2, width: size.width, height: size.height))
        } else {
            color.setFill(); rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: rect.height * 0.6, weight: .medium), .foregroundColor: foreground]
            let text = Self.initial(name) as NSString, size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX-size.width/2, y: rect.midY-size.height/2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Confined to HermesBridge's serial background queue. Failed decodes are cached too.
final class ProfileAvatarCache {
    private struct Stamp: Equatable { var path: String; var modified: Date?; var size: UInt64 }
    private struct Entry { var photo: Stamp; var metadata: Stamp; var avatar: ProfileAvatar }
    private var entries: [String: Entry] = [:]
    private(set) var imageReads = 0
    /// Creating an NSImage registers the process with the window server; the windowless share keeps only the CGImage.
    private let makesImages: Bool
    init(makesImages: Bool = true) { self.makesImages = makesImages }
    static func avatarURL(root: URL) -> URL? {
        ["slack-avatar.png", "avatar.png"].map { root.appendingPathComponent("assets/" + $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    private func stamp(_ url: URL?) -> Stamp {
        let attributes = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        return Stamp(path: url?.path ?? "", modified: attributes?[.modificationDate] as? Date,
                     size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
    }
    func load(profile: String, root: URL, url: URL?) -> ProfileAvatar {
        let photo = stamp(url), metadataURL = root.appendingPathComponent("profile.yaml"), metadata = stamp(metadataURL)
        let old = entries[profile]
        if let old, old.photo == photo, old.metadata == metadata { return old.avatar }
        var avatar = old?.avatar ?? ProfileAvatar()
        if old == nil || old?.photo != photo {
            avatar.image = nil; avatar.thumbnail = nil
            if let url {
                imageReads += 1
                if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: ChatMetrics.thumbnailPixels,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
                   ] as CFDictionary) {
                    if makesImages { avatar.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)) }
                    avatar.thumbnail = thumbnail
                }
            }
        }
        if old == nil || old?.metadata != metadata {
            let color = (try? String(contentsOf: metadataURL, encoding: .utf8)).flatMap(Self.profileColor)
            avatar.hasProfileColor = color != nil; avatar.color = color ?? .systemGray
        }
        entries[profile] = Entry(photo: photo, metadata: metadata, avatar: avatar)
        return avatar
    }
    /// Read only the supported nested ui_meta.hermes-bots.color scalar, never an unrelated color key.
    static func profileColor(_ text: String) -> NSColor? {
        var inUI = false, inBots = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 { inUI = trimmed == "ui_meta:"; inBots = false; continue }
            guard inUI else { continue }
            if indent == 2 { inBots = trimmed == "hermes-bots:"; continue }
            if inBots && indent == 4 && trimmed.hasPrefix("color:") {
                return parseColor(String(trimmed.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " \t'\"")))
            }
        }
        return nil
    }
    static func parseColor(_ value: String) -> NSColor? {
        if value.hasPrefix("#"), value.count == 7, let hex = UInt32(value.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
        }
        if value.hasPrefix("hsl("), value.hasSuffix(")") {
            let parts = value.dropFirst(4).dropLast().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            guard parts.count == 3, parts[1].hasSuffix("%"), parts[2].hasSuffix("%"),
                  let h = Double(parts[0]), let s = Double(parts[1].dropLast()), let l = Double(parts[2].dropLast()),
                  h.isFinite, (0...100).contains(s), (0...100).contains(l) else { return nil }
            let saturation = s/100, lightness = l/100
            let brightness = lightness + saturation * min(lightness, 1-lightness)
            return NSColor(calibratedHue: CGFloat((h.truncatingRemainder(dividingBy: 360)+360).truncatingRemainder(dividingBy: 360)/360),
                        saturation: CGFloat(brightness == 0 ? 0 : 2*(1-lightness/brightness)), brightness: CGFloat(brightness), alpha: 1)
        }
        return nil
    }
}
