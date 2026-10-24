import Foundation

struct TapContact: Equatable {
    var id: Int, x: Double, y: Double
}

/// Gesture state belongs to one device; each finger is compared with its own landing point.
struct ThreeTapGesture {
    static let duration = 0.3, movement = 0.04, cooldown = 0.4
    private var began: Double?, lastFrame: Double?, lastTap = -Double.infinity
    private var landings: [Int: TapContact] = [:]
    private var peak = 0, rejected = false
    mutating func receive(_ contacts: [TapContact], at time: Double) -> Bool {
        guard time.isFinite, time >= 0, lastFrame.map({ time >= $0 }) ?? true else { cancel(); return false }
        lastFrame = time
        if contacts.isEmpty {
            let tapped = began.map { time-$0 <= Self.duration && peak == 3 && !rejected && time-lastTap >= Self.cooldown } ?? false
            cancel()
            if tapped { lastTap = time }
            return tapped
        }
        if began == nil { began = time }
        peak = max(peak, contacts.count)
        if peak > 3 || time-began! > Self.duration { rejected = true }
        for contact in contacts {
            guard contact.x.isFinite, contact.y.isFinite, (0...1).contains(contact.x), (0...1).contains(contact.y) else { rejected = true; continue }
            let first = landings[contact.id] ?? contact
            landings[contact.id] = first
            if hypot(contact.x-first.x, contact.y-first.y) > Self.movement { rejected = true }
        }
        if landings.count > 3 { rejected = true }
        return false
    }
    private mutating func cancel() { began = nil; landings = [:]; peak = 0; rejected = false }
}

enum ThreeTapHealth: Equatable {
    case checking, ready, absent, failed(String)
    var failure: String? { if case .failed(let reason) = self { return reason }; return nil }
}

struct ThreeTapFailure: Codable, Equatable {
    var mac: String, os: String, build: String, app: String, appBuild: String, stage: String
    var key: String { [os, build, app, appBuild, stage].joined(separator: "|") }
    var valid: Bool { [mac, os, build, app, appBuild, stage].allSatisfy { !$0.isEmpty && $0.count <= 200 && !$0.contains("\n") && !$0.contains("\r") && !$0.uppercased().contains("MEDIA:") } }
    var request: String {
        """
        현재 macOS에서 ddots의 세 손가락 탭 기능이 작동하지 않아요. macOS 업데이트와 비공개 MultitouchSupport 변경을 분석해 다시 작동하는 버전으로 개선해 주세요.
        Mac: \(mac)
        macOS: \(os) (\(build))
        ddots: \(app) (\(appBuild))
        실패 지점: \(stage)
        관련 파일: Sources/ThreeTap.swift, Sources/ThreeTapReader.swift, Sources/ThreeTapController.swift
        트랙패드 연결·콜백·접촉 구조체를 확인하고, 실제 탭과 자가 점검·알림 중복 억제를 검증해 주세요. 기존 펫 클릭은 유지해 주세요.
        """
    }
    var slackText: String { "[ddots · \(mac)] 세 손가락 탭을 껐어요. macOS \(os) (\(build)), ddots \(app) (\(appBuild)), 실패 지점: \(stage). ddots 알림에서 수정 요청문을 복사할 수 있어요." }
}

struct ThreeTapCheck {
    enum Notice: Equatable { case healthy, failure }
    var lastOS: String?
    var failures: Set<String> = []
    var pendingUpdate = false
    mutating func begin(os: String) {
        pendingUpdate = pendingUpdate || (lastOS != nil && lastOS != os)
        lastOS = os
        // Without a device a version change remains pending for the next launch.
    }
    mutating func receive(_ health: ThreeTapHealth, os: String, failureKey: String) -> Notice? {
        switch health {
        case .checking, .absent: return nil
        case .ready:
            let notify = pendingUpdate
            lastOS = os; pendingUpdate = false
            return notify ? .healthy : nil
        case .failed:
            lastOS = os; pendingUpdate = false
            return failures.insert(failureKey).inserted ? .failure : nil
        }
    }
}

struct ThreeTapContact {
    var id: Int, state: Int, x: Double, y: Double
}

struct ThreeTapFrames {
    static let failureLimit = 30
    static let coordinateRange = -0.05...1.05
    enum Result: Equatable { case ignored, valid(tapped: Bool), failed(String) }
    private var gesture = ThreeTapGesture()
    private var lastTime: Double?
    private var invalidCount = 0, awaitingRelease = false
    mutating func receive(_ contacts: [ThreeTapContact]?, count: Int, at time: Double) -> Result {
        if time.isFinite, time >= 0, let lastTime, time < lastTime {
            gesture = ThreeTapGesture(); awaitingRelease = true; invalidCount = 0; self.lastTime = time
            return .ignored
        }
        let reason: String?
        if !time.isFinite || time < 0 { reason = "시각" }
        else if !(0...16).contains(count) || contacts?.count != count { reason = "개수" }
        else if contacts!.contains(where: { !(0...7).contains($0.state) }) { reason = "상태" }
        else if contacts!.contains(where: { !Self.coordinateRange.contains($0.x) || !Self.coordinateRange.contains($0.y) }) { reason = "좌표" }
        else if Set(contacts!.map(\.id)).count != count { reason = "ID 중복" }
        else { reason = nil }
        if let reason {
            gesture = ThreeTapGesture(); awaitingRelease = true; invalidCount += 1
            return invalidCount >= Self.failureLimit ? .failed("접촉 프레임 검사: " + reason) : .ignored
        }
        lastTime = time; invalidCount = 0
        let active = contacts!.filter { $0.state == 3 || $0.state == 4 }.map {
            TapContact(id: $0.id, x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y)))
        }
        if awaitingRelease { if active.isEmpty { awaitingRelease = false }; return .valid(tapped: false) }
        return .valid(tapped: gesture.receive(active, at: time))
    }
}

struct ThreeTapDeviceIdentity {
    var pointer: UInt, id: UInt64?
    static func keep(_ current: [Self], _ next: [Self], allRunning: Bool, cfEqual: Bool) -> Bool {
        guard current.count == next.count else { return false }
        if current.isEmpty { return true }
        guard allRunning else { return false }
        let oldIDs = current.compactMap(\.id), newIDs = next.compactMap(\.id)
        if Set(oldIDs).count == current.count, Set(newIDs).count == next.count { return Set(oldIDs) == Set(newIDs) }
        if cfEqual || Set(current.map(\.pointer)) == Set(next.map(\.pointer)) { return true }
        // With no stable identity, keep live registrations rather than interrupting them every poll.
        return allRunning
    }
}
