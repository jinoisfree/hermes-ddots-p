import Foundation
import CryptoKit
import Security
import Darwin

enum ClipboardStoreError: Error { case keychain(OSStatus), unsafePath, invalidKey, invalidArchive }

/// The key name is injectable so tests never touch the production keychain item.
struct ClipboardKeychain {
    var service: String
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "clipboard-aes-gcm", kSecAttrSynchronizable as String: false] }
    func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClipboardStoreError.keychain(status) }
        guard let bytes = result as? Data, bytes.count == 32 else { throw ClipboardStoreError.invalidKey }
        return bytes
    }
    func create() throws -> Data {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var q = query
        q[kSecValueData as String] = bytes
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClipboardStoreError.keychain(status) }
        return bytes
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClipboardStoreError.keychain(status) }
    }
}

struct ClipboardArchive: Codable {
    var version = 1
    var entries: [ClipboardEntry] = []
    var tabs = ClipboardTabs()
}

/// Call on one serial queue. Neither original paths nor clipboard values are ever logged.
final class ClipboardStore {
    let root: URL
    let temporary: URL
    private let keychain: ClipboardKeychain
    private var key: SymmetricKey?
    private let fm = FileManager.default
    private(set) var recoveredUnreadable = false
    init(root: URL, temporary: URL, keychain: ClipboardKeychain) {
        func canonicalParent(_ url: URL) -> URL {
            let parent = url.deletingLastPathComponent()
            guard let path = realpath(parent.path, nil) else { return url }
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent(url.lastPathComponent)
        }
        self.root = canonicalParent(root)
        self.temporary = canonicalParent(temporary)
        self.keychain = keychain
    }
    private func prepare(_ url: URL) throws {
        // Reject links at every existing component, including the requested leaf.
        var part = url
        while part.path != "/" {
            if let attrs = try? fm.attributesOfItem(atPath: part.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw ClipboardStoreError.unsafePath }
            part.deleteLastPathComponent()
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func load() throws -> ClipboardArchive {
        try prepare(root); try prepare(temporary)
        try clearTemporary(); try clearTrash()
        let stored = try keychain.read()
        let index = root.appendingPathComponent("index.aes")
        let hasArchive = !(try fm.contentsOfDirectory(atPath: root.path)).isEmpty
        if stored == nil && hasArchive { try quarantine() }
        key = SymmetricKey(data: try stored ?? keychain.create())
        guard fm.fileExists(atPath: index.path) else { try removeOrphans(keeping: []); return ClipboardArchive() }
        do {
            let archive = try JSONDecoder().decode(ClipboardArchive.self, from: read(index))
            guard archive.version == 1, !archive.tabs.items.isEmpty,
                  Set(archive.tabs.items.map(\.id)).count == archive.tabs.items.count else { throw ClipboardStoreError.invalidArchive }
            // Validate all referenced blobs at startup. A damaged archive never leaks partial plaintext.
            for entry in archive.entries { if let id = entry.dataID { _ = try read(blobURL(id)) } }
            try removeOrphans(keeping: Set(archive.entries.compactMap(\.dataID)))
            return archive
        } catch {
            try quarantine()
            return ClipboardArchive()
        }
    }
    private func removeOrphans(keeping ids: Set<UUID>) throws {
        for name in try fm.contentsOfDirectory(atPath: root.path) {
            let file = root.appendingPathComponent(name)
            guard ["aes", "writing"].contains(file.pathExtension), let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
            try owned(file, under: root); try fm.removeItem(at: file)
        }
    }
    private func quarantine() throws {
        let destination = root.deletingLastPathComponent().appendingPathComponent(".unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
        try fm.moveItem(at: root, to: destination)
        recoveredUnreadable = true
        try prepare(root)
    }
    private func owned(_ url: URL, under directory: URL) throws {
        guard let actual = realpath(directory.path, nil) else { throw ClipboardStoreError.unsafePath }
        defer { free(actual) }
        guard String(cString: actual) == directory.path else { throw ClipboardStoreError.unsafePath }
        guard url.deletingLastPathComponent().path == directory.path else { throw ClipboardStoreError.unsafePath }
        if let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw ClipboardStoreError.unsafePath }
    }
    private func write(_ bytes: Data, to url: URL) throws {
        try owned(url, under: root)
        guard let key else { throw ClipboardStoreError.invalidKey }
        let encrypted = try AES.GCM.seal(bytes, using: key).combined!
        // The temporary file receives restrictive permissions before any ciphertext is written.
        let staging = root.appendingPathComponent(UUID().uuidString + ".writing")
        guard fm.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClipboardStoreError.unsafePath }
        do {
            try encrypted.write(to: staging)
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: staging) }
            else { try fm.moveItem(at: staging, to: url) }
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    private func read(_ url: URL) throws -> Data {
        try owned(url, under: root)
        guard let key else { throw ClipboardStoreError.invalidKey }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key)
    }
    func save(_ archive: ClipboardArchive) throws { try write(JSONEncoder().encode(archive), to: root.appendingPathComponent("index.aes")) }
    private func blobURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".aes") }
    func saveData(_ data: Data, id: UUID) throws { try write(data, to: blobURL(id)) }
    func data(_ id: UUID) throws -> Data { try read(blobURL(id)) }
    func removeData(_ id: UUID) throws {
        let url = blobURL(id); try owned(url, under: root)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
    var trash: URL { root.appendingPathComponent("trash", isDirectory: true) }
    func trashData(_ id: UUID) throws {
        try prepare(trash)
        let from = blobURL(id), to = trash.appendingPathComponent(id.uuidString + ".aes")
        try owned(from, under: root); try owned(to, under: trash)
        try fm.moveItem(at: from, to: to)
    }
    func restoreData(_ id: UUID) throws {
        let from = trash.appendingPathComponent(id.uuidString + ".aes"), to = blobURL(id)
        try owned(from, under: trash); try owned(to, under: root)
        try fm.moveItem(at: from, to: to)
    }
    func removeTrashData(_ id: UUID) throws {
        let url = trash.appendingPathComponent(id.uuidString + ".aes")
        try owned(url, under: trash)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
    func clearTrash() throws {
        guard fm.fileExists(atPath: trash.path) else { return }
        try owned(trash, under: root)
        for name in try fm.contentsOfDirectory(atPath: trash.path) {
            let file = trash.appendingPathComponent(name)
            try owned(file, under: trash)
            // Never recursively follow any path. This directory only owns ciphertext leaves.
            guard file.pathExtension == "aes", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { throw ClipboardStoreError.unsafePath }
            try fm.removeItem(at: file)
        }
        try fm.removeItem(at: trash)
    }
    func clearTemporary() throws {
        for name in try fm.contentsOfDirectory(atPath: temporary.path) {
            let url = temporary.appendingPathComponent(name); try owned(url, under: temporary)
            try fm.removeItem(at: url)
        }
    }
    func export(_ data: Data, extension suffix: String) throws -> URL {
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw ClipboardStoreError.unsafePath }
        let url = temporary.appendingPathComponent(UUID().uuidString + "." + suffix)
        try owned(url, under: temporary)
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClipboardStoreError.unsafePath }
        try data.write(to: url)
        return url
    }
}
