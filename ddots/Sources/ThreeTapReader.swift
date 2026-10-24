import Foundation
import Darwin

/// Private ABI: a 96-byte contact, with path/state at 16/20 and normalized x/y at 32/36.
/// No pointer or device is sent to the main queue. Consecutive invalid frames disable this reader.
final class ThreeTapReader {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Create = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Running = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias DeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private var deviceID: DeviceID?
    private typealias Dimensions = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private static weak var current: ThreeTapReader?
    private static let registry = NSLock()
    private static let callback: Callback = { device, data, count, time, _ in
        registry.lock(); let reader = current; registry.unlock()
        reader?.receive(device, data: data, count: count, time: time)
        return 0
    }
    var onHealth: ((ThreeTapHealth) -> Void)?
    var onTap: (() -> Void)?
    private let lock = NSLock()
    private static let loadedLibrary = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL)
    private var list: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var identities: [ThreeTapDeviceIdentity] = []
    private var frames: [UInt: ThreeTapFrames] = [:]
    private var generation = 0, confirmed = false, failed = false
    private var create: Create?, register: Register?, unregister: Register?, startDevice: Start?, stopDevice: Stop?, running: Running?, dimensions: Dimensions?
    private var timer: Timer?
    func start() {
        stop()
        guard let handle = Self.loadedLibrary else { onHealth?(.failed("dlopen")); return }
        var reported = false
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else {
                if !reported { reported = true; onHealth?(.failed("기호 없음: " + name)) }
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }
        deviceID = dlsym(handle, "MTDeviceGetDeviceID").map { unsafeBitCast($0, to: DeviceID.self) }
        create = symbol("MTDeviceCreateList", Create.self)
        register = symbol("MTRegisterContactFrameCallback", Register.self)
        unregister = symbol("MTUnregisterContactFrameCallback", Register.self)
        startDevice = symbol("MTDeviceStart", Start.self); stopDevice = symbol("MTDeviceStop", Stop.self)
        running = symbol("MTDeviceIsRunning", Running.self); dimensions = symbol("MTDeviceGetSensorDimensions", Dimensions.self)
        guard create != nil, register != nil, unregister != nil, startDevice != nil, stopDevice != nil, running != nil, dimensions != nil else { stop(); return }
        Self.registry.lock(); Self.current = self; Self.registry.unlock()
        refresh()
        guard create != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        lock.lock(); let broken = failed; lock.unlock()
        guard !broken, let create else { return }
        guard let next = create()?.takeRetainedValue() else { fail("기기 목록"); return }
        defer { withExtendedLifetime(next) {} }
        var found: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(next) {
            guard let value = CFArrayGetValueAtIndex(next, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: value)
            var rows: Int32 = 0, columns: Int32 = 0
            guard dimensions?(device, &rows, &columns) == 0 else { fail("센서 크기 조회"); return }
            // Touch Bars have only a few rows; their contacts must not toggle the conversation.
            if rows >= 10 && columns > 0 { found.append(device) }
        }
        func identity(_ device: UnsafeMutableRawPointer) -> ThreeTapDeviceIdentity {
            var id: UInt64 = 0
            let known = deviceID?(device, &id) == 0 && id != 0
            return ThreeTapDeviceIdentity(pointer: UInt(bitPattern: device), id: known ? id : nil)
        }
        let nextIdentities = found.map(identity)
        let equal = devices.count == found.count && devices.allSatisfy { old in
            found.contains { CFEqual(Unmanaged<CFTypeRef>.fromOpaque(old).takeUnretainedValue(), Unmanaged<CFTypeRef>.fromOpaque($0).takeUnretainedValue()) }
        }
        if ThreeTapDeviceIdentity.keep(identities, nextIdentities, allRunning: devices.allSatisfy { running?($0) == true }, cfEqual: equal) {
            // Keep the original CFArray owning registered devices; the unused new array is released by ARC.
            if found.isEmpty { onHealth?(.absent) }
            return
        }
        detach()
        list = next; devices = found; identities = nextIdentities
        lock.lock(); generation += 1; confirmed = false; frames = Dictionary(uniqueKeysWithValues: found.map { (UInt(bitPattern: $0), ThreeTapFrames()) }); lock.unlock()
        if found.isEmpty { onHealth?(.absent); return }
        onHealth?(.checking)
        for device in found {
            register?(device, Self.callback); startDevice?(device, 0)
            if running?(device) != true { fail("기기 시작·등록 확인"); return }
        }
    }
    func reconnect() { detach(); refresh() }
    private func detach() {
        lock.lock(); generation += 1; frames = [:]; lock.unlock()
        for device in devices { stopDevice?(device); unregister?(device, Self.callback) }
        devices = []; identities = []; list = nil
    }
    func stop() {
        timer?.invalidate(); timer = nil
        detach()
        Self.registry.lock(); if Self.current === self { Self.current = nil }; Self.registry.unlock()
        lock.lock(); failed = false; confirmed = false; lock.unlock()
        // A late private-framework callback can still be on its stack: keep the library resident.
        deviceID = nil; create = nil; register = nil; unregister = nil; startDevice = nil; stopDevice = nil; running = nil; dimensions = nil
    }
    private func fail(_ stage: String) {
        lock.lock(); failed = true; lock.unlock()
        onHealth?(.failed(stage))
    }
    private func receive(_ device: UnsafeMutableRawPointer?, data: UnsafeRawPointer?, count: Int32, time: Double) {
        guard let device else { return }
        lock.lock()
        let key = UInt(bitPattern: device), epoch = generation
        guard !failed, var state = frames[key] else { lock.unlock(); return }
        var contacts: [ThreeTapContact]? = count == 0 ? [] : nil
        if (1...16).contains(count), let data {
            contacts = (0..<Int(count)).map { i in
                let raw = data.advanced(by: i*96)
                return ThreeTapContact(id: Int(raw.load(fromByteOffset: 16, as: Int32.self)), state: Int(raw.load(fromByteOffset: 20, as: Int32.self)),
                                       x: Double(raw.load(fromByteOffset: 32, as: Float.self)), y: Double(raw.load(fromByteOffset: 36, as: Float.self)))
            }
        }
        let result = state.receive(contacts, count: Int(count), at: time); frames[key] = state
        if case .failed(let reason) = result {
            failed = true; lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let active = self.generation == epoch && self.failed; self.lock.unlock()
                if active { self.onHealth?(.failed(reason)) }
            }
            return
        }
        guard case .valid(let tapped) = result else { lock.unlock(); return }
        let first = !confirmed; confirmed = true
        lock.unlock()
        if first || tapped {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let active = self.generation == epoch && !self.failed; self.lock.unlock()
                guard active else { return }
                if first { self.onHealth?(.ready) }
                if tapped { self.onTap?() }
            }
        }
    }
    deinit { stop() }
}
