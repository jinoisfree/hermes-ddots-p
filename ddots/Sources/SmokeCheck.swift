import Foundation

/// A UI check that failed: says which, clears away what the run put on disk, and ends with a failure code.
/// A trap would leave a crash report behind for every failed check and, from an optimized build, say nothing.
func smokeFailed(_ message: String = "", file: StaticString = #fileID, line: UInt = #line) -> Never {
    FileHandle.standardError.write(Data("UI check failed: \(message.isEmpty ? "(no message)" : message) (\(file):\(line))\n".utf8))
    SmokeLeftovers.clear()
    exit(1)
}

func smokeCheck(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition() { smokeFailed(message(), file: file, line: line) }
}

/// The folders a UI check makes for itself, taken away when the run ends, whichever way it ends.
enum SmokeLeftovers {
    private static var folders: [URL] = []
    static func note(_ folder: URL) { folders.append(folder) }
    static func clear() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }
}
