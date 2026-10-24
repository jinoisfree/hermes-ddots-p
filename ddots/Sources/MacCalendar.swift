import AppKit
import EventKit
import SwiftUI

// EventKit objects stay on the service's serial queue. Only value snapshots reach the UI.
enum CalendarAccess: Equatable { case unknown, allowed, denied }
protocol CalendarSource: AnyObject {
    var access: CalendarAccess { get }
    func requestAccess(_ completion: @escaping () -> Void)
    func events(from: Date, to: Date) -> [CalendarEntry]
}
final class EventKitCalendarSource: CalendarSource {
    private lazy var store = EKEventStore()
    var access: CalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if status == .fullAccess { return .allowed }
            if status == .writeOnly { return .unknown }
        } else if status == .authorized { return .allowed }
        return status == .notDetermined ? .unknown : .denied
    }
    func requestAccess(_ completion: @escaping () -> Void) {
        if #available(macOS 14.0, *) { store.requestFullAccessToEvents { _, _ in completion() } }
        else { store.requestAccess(to: .event) { _, _ in completion() } }
    }
    func events(from: Date, to: Date) -> [CalendarEntry] {
        guard access == .allowed else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).compactMap { event in
            guard event.status != .canceled, let identifier = event.eventIdentifier, let start = event.startDate, let end = event.endDate else { return nil }
            return CalendarEntry(identifier: identifier, calendarID: event.calendar.calendarIdentifier,
                                 title: event.title ?? "제목 없는 일정", start: start, end: end, allDay: event.isAllDay,
                                 calendar: event.calendar.title, location: event.location ?? "", notes: event.notes ?? "")
        }
    }
}

final class MacCalendar: ObservableObject {
    @Published private(set) var events: [CalendarEntry] = []
    @Published private(set) var access: CalendarAccess = .unknown
    @Published private(set) var loading = false
    @Published private(set) var selected: CalendarEntry?
    @Published private(set) var notice: String?
    @Published var query = ""
    @Published private(set) var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @Published private(set) var relatedIDs: Set<String>?
    var onChange: (([CalendarEntry]) -> Void)?
    private let source: CalendarSource
    private let queue = DispatchQueue(label: "io.github.hermes-ddots-p.ddots.calendar", qos: .userInitiated)
    private var lastRead = Date.distantPast
    private var reloadWanted = false
    private var accessRequestWanted = false
    private var generation = 0
    private var observer: NSObjectProtocol?
    init(source: CalendarSource = EventKitCalendarSource(), observe: Bool = true) {
        self.source = source
        if observe {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                self?.invalidate(); self?.refresh(force: true)
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func invalidate() {
        generation += 1; events = []; selected = nil; onChange?([])
    }
    /// No EventKit access from smoke tests: those inject a synthetic CalendarSource instead.
    func refresh(force: Bool = false, requestAccess: Bool = false) {
        guard !loading else { if force { reloadWanted = true }; accessRequestWanted = accessRequestWanted || requestAccess; return }
        guard force || Date().timeIntervalSince(lastRead) >= 60 else { return }
        loading = true
        let revision = generation, browseMonth = month
        queue.async { [self] in
            if requestAccess && source.access == .unknown {
                source.requestAccess { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.read(revision: revision, month: browseMonth) }
                }
            } else { read(revision: revision, month: browseMonth) }
        }
    }
    private func read(revision: Int, month: Date) {
        let status = source.access, calendar = Calendar.current, now = Date()
        var loaded: [CalendarEntry] = []
        if status == .allowed {
            // Related replies use recent/upcoming events; the browser can separately load any month.
            let start = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))!
            let end = calendar.date(byAdding: .day, value: 181, to: now)!
            loaded = source.events(from: start, to: end)
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: month)!
            if month < start || monthEnd > end { loaded += source.events(from: month, to: monthEnd) }
        }
        var seen = Set<String>()
        let values = loaded.filter { seen.insert($0.id).inserted }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        DispatchQueue.main.async { [self] in
            loading = false
            if generation == revision {
                access = status; events = status == .allowed ? values : []; lastRead = Date()
                if let selected { self.selected = events.first { $0.id == selected.id } }
                if status != .allowed { selected = nil }
                onChange?(events)
            }
            if reloadWanted || generation != revision || accessRequestWanted {
                let request = accessRequestWanted
                reloadWanted = false; accessRequestWanted = false
                refresh(force: true, requestAccess: request)
            }
        }
    }
    func browse() { generation += 1; relatedIDs = nil; selected = nil; notice = nil; query = ""; refresh(force: true, requestAccess: true) }
    func moveMonth(_ offset: Int) {
        generation += 1
        month = Calendar.current.date(byAdding: .month, value: offset, to: month)!
        selected = nil; notice = nil; refresh(force: true)
    }
    var visibleEvents: [CalendarEntry] {
        let end = Calendar.current.date(byAdding: .month, value: 1, to: month)!
        return events.filter { event in
            let included = relatedIDs.map { $0.contains(event.id) } ?? (event.start < end && event.end > month)
            return included && (query.isEmpty || (event.title + " " + event.location).localizedCaseInsensitiveContains(query))
        }
    }
    func showRelated(_ references: [CalendarEntry]) {
        generation += 1
        relatedIDs = Set(references.map(\.id)); selected = nil; notice = nil; query = ""
        if references.count == 1, let reference = references.first { select(reference) }
        else { refresh(force: true) }
    }
    /// Re-read the exact occurrence on every click. Deleted/moved occurrences cannot open a different event.
    func select(_ reference: CalendarEntry) {
        generation += 1
        let revision = generation
        selected = nil; notice = "일정을 확인하는 중…"
        queue.async { [self] in
            let status = source.access
            let candidates = status == .allowed ? source.events(from: reference.start.addingTimeInterval(-1), to: max(reference.end, reference.start.addingTimeInterval(1))) : []
            let found = candidates.first { $0.id == reference.id }
            DispatchQueue.main.async { [self] in
                guard generation == revision else { return }
                access = status; selected = found
                if status != .allowed { events = []; onChange?([]) }
                else if found == nil { events.removeAll { $0.id == reference.id }; onChange?(events) }
                notice = found != nil ? nil : (status == .allowed ? "이 일정이 삭제되거나 변경됐어요. 새로고침해 주세요." : "캘린더 접근 권한을 허용해 주세요.")
            }
        }
    }
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }
}

struct MacCalendarView: View {
    @ObservedObject var model: MacCalendar
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.relatedIDs == nil ? "내 캘린더" : "대화와 관련된 일정").font(.title2.bold())
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("새로고침") { model.refresh(force: true, requestAccess: true) }
            }
            if model.access != .allowed {
                Text("Mac 캘린더의 일정을 조회하고 대화와 관련된 일정을 열려면 캘린더 전체 접근을 허용해 주세요.")
                HStack {
                    Button("캘린더 접근 허용") { model.refresh(force: true, requestAccess: true) }
                    Button("권한 설정 열기") { model.openSettings() }
                }
            } else {
                if model.relatedIDs == nil {
                    HStack {
                        Button("이전 달") { model.moveMonth(-1) }
                        Text(model.month.formatted(.dateTime.year().month(.wide))).frame(maxWidth: .infinity)
                        Button("다음 달") { model.moveMonth(1) }
                    }
                } else { Button("전체 캘린더 보기") { model.browse() } }
                TextField("제목 또는 장소 검색", text: $model.query)
                HSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if model.visibleEvents.isEmpty { Text(model.loading ? "조회 중…" : "표시할 일정이 없어요.").foregroundColor(.secondary).padding() }
                            ForEach(model.visibleEvents) { event in
                                Button { model.select(event) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(event.title).font(.headline)
                                        Text(event.start.formatted(date: .abbreviated, time: event.allDay ? .omitted : .shortened))
                                        Text(event.calendar).font(.caption).foregroundColor(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        .background(model.selected?.id == event.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                        .cornerRadius(8)
                                }.buttonStyle(.plain).accessibilityIdentifier("calendar-event-" + event.id)
                            }
                        }
                    }.frame(minWidth: 230)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let event = model.selected {
                                Text(event.title).font(.title2.bold())
                                Text(event.calendar).foregroundColor(.secondary)
                                Text(event.allDay ? "종일" : "시간").font(.headline)
                                Text(event.start.formatted(date: .complete, time: event.allDay ? .omitted : .shortened))
                                Text("~ " + (event.allDay ? event.end.addingTimeInterval(-1) : event.end).formatted(date: .complete, time: event.allDay ? .omitted : .shortened))
                                if !event.location.isEmpty { Text("장소").font(.headline); Text(event.location) }
                                if !event.notes.isEmpty { Text("메모").font(.headline); Text(event.notes) }
                            } else { Text(model.notice ?? "일정을 선택하면 상세 내용을 볼 수 있어요.").foregroundColor(.secondary) }
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.frame(minWidth: 250)
                }
            }
        }.padding(20).frame(minWidth: 620, minHeight: 430)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
