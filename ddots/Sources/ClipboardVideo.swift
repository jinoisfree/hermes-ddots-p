import AppKit
import AVFoundation

/// AVFoundation reads decrypted video from memory. Viewing a card never creates a plaintext movie on disk.
private final class ClipboardVideoBytes: NSObject, AVAssetResourceLoaderDelegate {
    let data: Data
    let type: String
    init(data: Data, type: String) { self.data = data; self.type = type }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = type; info.contentLength = Int64(data.count); info.isByteRangeAccessSupported = true
        }
        if let read = request.dataRequest {
            let offset = read.currentOffset == 0 ? read.requestedOffset : read.currentOffset
            guard offset >= 0, offset <= data.count else { request.finishLoading(with: NSError(domain: "ClipboardVideo", code: 1)); return true }
            let start = Int(offset)
            let length = read.requestsAllDataToEndOfResource ? data.count - start : min(read.requestedLength, data.count - start)
            read.respond(with: data.subdata(in: start..<(start + length)))
        }
        request.finishLoading(); return true
    }
}

enum ClipboardVideo {
    static func thumbnail(data: Data, type: String) async -> (NSImage?, String?) {
        let provider = ClipboardVideoBytes(data: data, type: type)
        let asset = AVURLAsset(url: URL(string: "ddots-clipboard://video/item")!)
        asset.resourceLoader.setDelegate(provider, queue: DispatchQueue(label: "ddots.clipboard.video-bytes"))
        let result = await thumbnail(asset: asset)
        withExtendedLifetime(provider) {}
        return result
    }
    static func thumbnail(file: URL) async -> (NSImage?, String?) { await thumbnail(asset: AVURLAsset(url: file)) }
    private static func thumbnail(asset: AVAsset) async -> (NSImage?, String?) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        let image = (try? await generator.image(at: .zero)).map { NSImage(cgImage: $0.image, size: .zero) }
        let seconds = (try? await asset.load(.duration).seconds) ?? .nan
        let duration = seconds.isFinite && seconds >= 0 ? String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) : nil
        return (image, duration)
    }
}
