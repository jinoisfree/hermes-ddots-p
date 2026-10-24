import Foundation

final class FixtureCalendarSource: CalendarSource {
    var access: CalendarAccess = .allowed
    var values: [CalendarEntry] = []
    var requests = 0
    func requestAccess(_ completion: @escaping () -> Void) { requests += 1; completion() }
    func events(from: Date, to: Date) -> [CalendarEntry] { values.filter { $0.start < to && $0.end > from } }
}

@main struct CalendarTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2030, month: 10, day: 5))!
        func event(_ title: String, _ offset: Int = 0, location: String = "") -> CalendarEntry {
            let start = day.addingTimeInterval(Double(offset * 86400 + 36000))
            return CalendarEntry(identifier: "series-" + title, calendarID: "fixture", title: title, start: start, end: start.addingTimeInterval(3600), location: location)
        }
        let dental = event("치과"), nextDental = event("치과", 1), meeting = event("제품 설계 검토", 1, location: "강남역")
        let values = [dental, nextDental, meeting]
        func matches(_ body: String) -> [CalendarEntry] { CalendarMatch.related(to: body, at: day, events: values, calendar: calendar) }
        precondition(matches("내일 치과 예약").map(\.id) == [nextDental.id], "relative dates use message time, not current time")
        precondition(matches("10월 5일 치과").map(\.id) == [dental.id])
        precondition(matches("2030-10-06 치과").map(\.id) == [nextDental.id])
        precondition(matches("치과 일정 알려 줘").count == 2, "ambiguous recurrences are shown as choices")
        precondition(matches("오늘 치과대학 입시 설명").isEmpty, "short titles cannot match unrelated words")
        precondition(matches("강남역 주차장 24시간 운영 00:00~24:00, 회의 때 참고").isEmpty)
        precondition(matches("내일 강남역 근처 주차장").map(\.id) == [meeting.id], "specific location plus a date relates a parking discussion to an actual appointment")
        precondition(matches("오늘 10:00 회의 일정").isEmpty, "a matching hour is insufficient")
        precondition(matches("2030-10-08 제품 설계 검토").isEmpty)
        precondition(matches("October 6, 2030 치과").map(\.id) == [nextDental.id])
        precondition(matches("이번 주 일요일 치과").map(\.id) == [nextDental.id])
        precondition(matches("다음 주 치과").isEmpty)
        _ = matches("٢٠٣٠년 ١٠월 ٥일 치과") // Untrusted Unicode numerals must not crash date parsing.
        precondition(CalendarMatch.related(to: "오늘 회의", at: day, events: [event("회의")], calendar: calendar).isEmpty, "generic titles do not invent relevance")
        let sameInOtherCalendar = CalendarEntry(identifier: dental.identifier, calendarID: "other", title: dental.title, start: dental.start, end: dental.end)
        precondition(CalendarMatch.related(to: "오늘 치과", at: day, events: [dental, dental, sameInOtherCalendar], calendar: calendar).count == 2)

        let source = FixtureCalendarSource()
        let now = Date()
        let current = CalendarEntry(identifier: "synthetic", calendarID: "fixture", title: "캘린더 연결 점검", start: now, end: now.addingTimeInterval(3600), calendar: "테스트", location: "테스트 회의실")
        source.values = [current]
        let model = MacCalendar(source: source, observe: false)
        func awaitResult(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(predicate(), "calendar callback timed out")
        }
        model.browse(); awaitResult { !model.loading }
        precondition(model.events == [current] && model.visibleEvents == [current])
        model.showRelated([current]); awaitResult { model.selected != nil }
        precondition(model.selected?.id == current.id && model.selected?.location == "테스트 회의실")
        source.values = []
        model.select(current); awaitResult { model.notice?.contains("삭제") == true }
        precondition(model.selected == nil && model.events.isEmpty, "deletion at click hides the obsolete button and never opens a different event")
        source.values = [current]; source.access = .denied
        model.refresh(force: true); awaitResult { !model.loading }
        precondition(model.events.isEmpty && model.access == .denied && model.selected == nil)
        model.refresh(force: true, requestAccess: true); awaitResult { !model.loading }
        precondition(source.requests == 0, "denial uses Settings instead of repeated permission prompts")
        source.access = .unknown
        model.refresh(force: true, requestAccess: true); awaitResult { !model.loading }
        precondition(source.requests == 1 && model.events.isEmpty)
        source.access = .allowed
        model.refresh(force: true); awaitResult { !model.loading }
        precondition(model.events.count == 1, "granting permission restores available events")
        model.query = "없는 일정"
        precondition(model.visibleEvents.isEmpty)
        print("Calendar matching, actual-event selection, deletion, permissions, refresh and search: PASS")
    }
}
