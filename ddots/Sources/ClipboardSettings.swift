import Foundation

struct ClipboardSettings: Codable {
    var enabled = true
    var days = 1
    var count = 100
    var media = true
    var ocr = true
    var copyNotifications = true
    var fitsContents = false
    var semanticSearch = false
    var hotKeyEnabled = true
    var hotKeyCode: UInt32 = 9
    var hotKeyModifiers: UInt32 = (1 << 8) | (1 << 12)
    var excludedApps: [String] = []
    static let key = "clipboardSettings"
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let bytes = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: bytes) else { return Self() }
        return value
    }
}

extension ClipboardSettings {
    private enum CodingKeys: String, CodingKey { case enabled, days, count, media, ocr, excludedApps, copyNotifications, fitsContents, semanticSearch, hotKeyEnabled, hotKeyCode, hotKeyModifiers }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        days = try values.decodeIfPresent(Int.self, forKey: .days) ?? 1
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 100
        media = try values.decodeIfPresent(Bool.self, forKey: .media) ?? true
        ocr = try values.decodeIfPresent(Bool.self, forKey: .ocr) ?? true
        excludedApps = try values.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
        copyNotifications = try values.decodeIfPresent(Bool.self, forKey: .copyNotifications) ?? true
        fitsContents = try values.decodeIfPresent(Bool.self, forKey: .fitsContents) ?? false
        semanticSearch = try values.decodeIfPresent(Bool.self, forKey: .semanticSearch) ?? false
        hotKeyEnabled = try values.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? true
        hotKeyCode = try values.decodeIfPresent(UInt32.self, forKey: .hotKeyCode) ?? 9
        hotKeyModifiers = try values.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? ((1 << 8) | (1 << 12))
    }
}
