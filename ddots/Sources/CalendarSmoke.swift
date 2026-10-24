import AppKit

/// Calendar UI checks never instantiate an EventKit store or ask for system permissions.
private final class SmokeCalendarSource: CalendarSource {
    var access: CalendarAccess { .allowed }
    let values: [CalendarEntry]
    init(_ values: [CalendarEntry]) { self.values = values }
    func requestAccess(_ completion: @escaping () -> Void) { completion() }
    func events(from: Date, to: Date) -> [CalendarEntry] { values.filter { $0.start < to && $0.end > from } }
}

extension AppDelegate {
    func verifyCalendar(destination: URL) {
        guard IMessageFeature.enabled else { print("SKIP: iMessage calendar UI; calendar unit tests retained"); NSApp.terminate(nil); return }
        let now = Date()
        let event = CalendarEntry(identifier: "synthetic-ui", calendarID: "fixture", title: "캘린더 연결 점검", start: now,
                                  end: now.addingTimeInterval(3600), calendar: "합성 일정", location: "테스트 회의실", notes: "실제 계정에 저장되지 않는 화면 검증용 일정입니다.")
        calendar = MacCalendar(source: SmokeCalendarSource([event]), observe: false)
        calendar.onChange = { [weak self] in self?.chat.calendarEvents = $0 }
        calendar.browse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            smokeCheck(calendar.events == [event], "Calendar browser reads only the injected fixture")
            let reply = ChatMessage(id: "calendar-smoke", fromUser: false, speaker: "개인비서", body: "오늘 캘린더 연결 점검이 있어.", date: now)
            let actions = chat.actions(for: reply)
            smokeCheck(actions.count == 1 && actions[0].kind == .showCalendar([event]), "Chat button targets an actual calendar occurrence")
            chat.onAction?(actions[0])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                smokeCheck(calendar.selected == event && calendarWindow?.isVisible == true, "Chat action opens the selected event details")
                if let view = calendarWindow?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("calendar-details.png"))
                }
                try? "PASS: synthetic calendar query → chat action → exact occurrence details, no real calendar access\n".write(to: destination.appendingPathComponent("calendar.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }
}
