import AppKit
import Foundation

/// Keeps the Slack side's screen choices alike on every Mac signed in to the same Slack account. What is kept and
/// how two Macs' choices meet is in `SettingsSync.swift`. Window sizes, the room on screen and the like stay per Mac.
extension SlackController {
    static var syncDevice: String {
        let key = "settingsSyncDevice"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
    static let syncObserveEvery: TimeInterval = 1.5

    /// This Mac's shared choices as keys and values.
    func syncedState() -> [String: String] {
        var state: [String: String] = [:]
        for (room, at) in retention.filtered(lastRead) { state["r:last:" + room] = String(at) }
        let threads = Dictionary(localThreads.map { ("slack:" + $0.key, $0.value) }, uniquingKeysWith: max)
        for (id, at) in retention.filtered(threads) { state["r:thread:" + id] = String(at) }
        for (id, at) in retention.filtered(confirmed) { state["r:confirmed:" + id] = String(at) }
        for (id, at) in retention.filtered(deletedThreads) { state["r:deleted:" + id] = String(at) }
        for (id, at) in retention.filtered(dismissed) { state["dismissed:" + id] = String(at) }
        state["sections"] = model.sections.map(String.init).joined(separator: ",")
        for (room, zone) in model.zoneOf { state["zone:" + room] = String(zone) }
        for zone in model.groupsOpen { state["open:" + String(zone)] = "1" }
        for (zone, name) in model.groupNames { state["name:" + String(zone)] = name }
        state["pins"] = (try? JSONEncoder().encode(model.pins)).flatMap { String(data: $0, encoding: .utf8) }
        for room in model.hidden { state["hidden:" + room] = "1" }
        for room in model.muted { state["muted:" + room] = "1" }
        for room in model.unkept { state["unkept:" + room] = "1" }
        state["chatMuted"] = model.chatMuted ? "1" : "0"
        state["stackOpen"] = model.stackOpen ? "1" : "0"
        return state
    }

    /// Called on every Slack beat: takes up what other Macs chose and passes on what changed here.
    func syncSettings(force: Bool = false) {
        guard persists, !closing, SettingsSync.validUser(snapshot.me) else { return }
        guard let settings, settings.user == snapshot.me else { joinSettings(snapshot.me); return }
        var changed = settings.refresh()
        if force || !syncExplicit.isEmpty || Date().timeIntervalSince(syncObservedAt) >= Self.syncObserveEvery {
            syncObservedAt = Date()
            var mine = SettingsSync.changes(from: syncObserved, to: syncedState(), at: Date().timeIntervalSince1970, by: Self.syncDevice)
            mine.merge(syncExplicit) { _, explicit in explicit }
            syncExplicit = [:]
            if !mine.isEmpty {
                changed.merge(settings.merge(mine)) { _, latest in latest }
                syncSend?(mine, settings.user, false)
            }
        }
        if !changed.isEmpty { applySynced(changed) }
    }

    /// Entries that came over the relay from the Mac that keeps the original.
    func receiveSynced(user: String, entries: [String: SyncEntry]) {
        syncSettings(force: true)
        guard let settings, settings.user == user, !entries.isEmpty else { return }
        let changed = settings.merge(entries)
        if !changed.isEmpty { applySynced(changed) }
    }
    /// Everything held here, sent again once the relay is back: what changed while it was away goes through.
    func syncSendAll() {
        syncSettings(force: true)
        guard let settings, !settings.entries.isEmpty else { return }
        syncSend?(settings.entries, settings.user, false)
    }

    /// The first time this Mac meets the account's choices. Its own reads go in as they are; its other choices go
    /// in as the oldest there are, so a Mac joining later takes up the screen the others already share.
    private func joinSettings(_ user: String) {
        guard let store = SettingsStore(user: user) else { return }
        settings = store; syncedThreadRead = [:]; syncExplicit = [:]
        let joined = "settingsSyncJoined." + user
        if !UserDefaults.standard.bool(forKey: joined) {
            var seed = SettingsSync.changes(from: [:], to: syncedState(), at: 1, by: Self.syncDevice)
            seed.merge(pictureEntries(at: 1)) { first, _ in first }
            store.merge(seed)
            UserDefaults.standard.set(true, forKey: joined)
        }
        _ = store.refresh()
        applySynced(store.entries)
        // Also tells the keeping Mac whose choices this Mac wants to hear about.
        syncSend?(store.entries, user, false)
    }

    /// Makes this Mac's sections, order, folds, mutes and pictures the ones every other Mac shows.
    @discardableResult func makeSyncStandard() -> Bool {
        syncSettings(force: true)
        guard let settings else { return false }
        let at = Date().timeIntervalSince1970
        var entries = SettingsSync.changes(from: [:], to: syncedState(), at: at, by: Self.syncDevice).filter { SettingsSync.isLayout($0.key) }
        entries.merge(pictureEntries(at: at)) { first, _ in first }
        let changed = settings.merge(entries, replacing: true, at: at, by: Self.syncDevice)
        syncSend?(entries, settings.user, true)
        if !changed.isEmpty { applySynced(changed) }
        return true
    }

    func syncPicture(_ key: String) {
        guard persists else { return }
        let data = SlackRoomPictures.data(key)
        syncExplicit["picture:" + key] = SyncEntry(v: data?.base64EncodedString(), at: Date().timeIntervalSince1970, by: Self.syncDevice)
    }
    func syncUndismiss(_ id: String) {
        guard persists else { return }
        syncExplicit["dismissed:" + id] = SyncEntry(v: nil, at: Date().timeIntervalSince1970, by: Self.syncDevice)
    }
    private func pictureEntries(at: Double) -> [String: SyncEntry] {
        var result: [String: SyncEntry] = [:]
        for key in SlackRoomPictures.keys() { if let data = SlackRoomPictures.data(key) { result["picture:" + key] = SyncEntry(v: data.base64EncodedString(), at: at, by: Self.syncDevice) } }
        return result
    }

    /// Puts shared choices on screen and saves them as this Mac's own.
    func applySynced(_ entries: [String: SyncEntry]) {
        var retentionChanged = false
        for (key, entry) in entries {
            let value = entry.v
            func rest(_ prefix: String) -> String? { key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil }
            let number = value.flatMap(Double.init)
            if let room = rest("r:last:"), let number { lastRead[room] = max(lastRead[room] ?? 0, number) }
            else if let id = rest("r:thread:"), let number { syncedThreadRead[id] = max(syncedThreadRead[id] ?? 0, number) }
            else if let id = rest("r:confirmed:"), let number { confirmed[id] = max(confirmed[id] ?? 0, number) }
            else if let id = rest("r:deleted:"), let number {
                if deletedThreads[id] == nil { model.release(thread: id) }
                deletedThreads[id] = max(deletedThreads[id] ?? 0, number)
            }
            else if let id = rest("dismissed:") { dismissed[id] = number }
            else if let room = rest("zone:") { model.zoneOf[room] = value.flatMap { Int($0) } }
            else if let zone = rest("open:").flatMap({ Int($0) }) { if value == nil { model.groupsOpen.remove(zone) } else { model.groupsOpen.insert(zone) } }
            else if let zone = rest("name:").flatMap({ Int($0) }) { model.groupNames[zone] = value }
            else if let room = rest("hidden:") { if value == nil { model.hidden.remove(room) } else { model.hidden.insert(room) }; retentionChanged = true }
            else if let room = rest("muted:") { if value == nil { model.muted.remove(room) } else { model.muted.insert(room) } }
            else if let room = rest("unkept:") { if value == nil { model.unkept.remove(room) } else { model.unkept.insert(room) }; retentionChanged = true }
            else if let picture = rest("picture:") {
                if let data = value.flatMap({ Data(base64Encoded: $0) }), let image = SlackRoomPictures.save(data: data, room: picture) { model.roomPictures[picture] = image }
                else if value == nil { SlackRoomPictures.remove(picture); model.roomPictures[picture] = nil }
            }
            else if key == "sections", let list = value?.split(separator: ",").compactMap({ Int($0) }), !list.isEmpty, !list.contains(Ddots.directZone) { model.sections = list }
            else if key == "pins", let data = value?.data(using: .utf8), let pins = try? JSONDecoder().decode([String].self, from: data), pins.count == SlackRoomOrder.slots { model.pins = pins }
            else if key == "chatMuted" { model.chatMuted = value == "1" }
            else if key == "stackOpen" { model.stackOpen = value == "1" }
        }
        saveSynced()
        if retentionChanged { changeRetention() }
        syncObserved = syncedState()
        publish()
    }

    /// The same keys each choice is saved under when it is made on this Mac.
    private func saveSynced() {
        let defaults = UserDefaults.standard
        defaults.set(retention.filtered(lastRead), forKey: "slackLastRead")
        defaults.set(retention.filtered(confirmed), forKey: "slackConfirmed")
        defaults.set(retention.filtered(dismissed), forKey: "slackDismissed")
        defaults.set(retention.filtered(deletedThreads), forKey: "slackDeletedThreads")
        defaults.set(model.sections, forKey: "slackSections")
        defaults.set(model.zoneOf, forKey: "slackZones")
        defaults.set(model.groupsOpen.sorted(), forKey: "slackGroupsOpen")
        defaults.set(Dictionary(uniqueKeysWithValues: model.groupNames.map { (String($0.key), $0.value) }), forKey: "slackGroupNames")
        defaults.set(model.pins, forKey: "slackPins")
        defaults.set(Array(model.hidden).sorted(), forKey: "slackHidden")
        defaults.set(Array(model.muted).sorted(), forKey: "slackMuted")
        defaults.set(model.chatMuted, forKey: "chatMuted")
        defaults.set(model.stackOpen, forKey: "slackStackOpen")
    }
}
