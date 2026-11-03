import Foundation
import Vision

enum ClipboardOCR {
    static let maximumBytes = 50 * 1024 * 1024
    /// Runs on the shelf's background queue. No network, diagnostics, or text preview output.
    static func recognize(data: Data) throws -> String? {
        guard data.count <= maximumBytes else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(data: data).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    static func recognize(file: URL) throws -> String? {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= maximumBytes else { return nil }
        return try recognize(data: Data(contentsOf: file, options: .mappedIfSafe))
    }
}
