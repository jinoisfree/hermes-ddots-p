import Foundation

/// A value copied from EventKit, never a date guessed from a reply. Recurrences keep their occurrence date.
struct CalendarEntry: Equatable, Identifiable {
    var identifier: String
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var calendar = ""
    var location = ""
    var notes = ""
    var id: String { calendarID + ":" + identifier + ":" + String(start.timeIntervalSince1970) }
}

enum CalendarMatch {
    private static let pattern = #"(?:([0-9]{4})\s*(?:년|[-/.])\s*)?([0-9]{1,2})\s*(?:월\s*|[-/])([0-9]{1,2})\s*일?"#
    private static let datePattern = try? NSRegularExpression(pattern: pattern)
    private static let englishMonths = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let english = "(?i)\\b(" + englishMonths.joined(separator: "|") + ")\\s+([0-9]{1,2})(?:,?\\s+([0-9]{4}))?\\b"
    private static let englishPattern = try? NSRegularExpression(pattern: english)
    private static let generic: Set<String> = ["일정", "회의", "미팅", "약속", "업무", "휴일", "휴무", "meeting", "event", "work"]
    private static func compact(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ko_KR"))
            .precomposedStringWithCanonicalMapping.filter { $0.isLetter || $0.isNumber }
    }
    private static func mentions(_ phrase: String, in text: String, compactText: String) -> Bool {
        let name = compact(phrase)
        guard name.count >= 2, !generic.contains(name) else { return false }
        if name.count >= 4 { return compactText.contains(name) }
        // Short names must be words, not pieces of an unrelated word (e.g. 치과 in 치과대학).
        let suffixes: Set<String> = ["", "은", "는", "이", "가", "을", "를", "에", "에서", "으로", "로", "와", "과", "도", "야", "이야"]
        return text.components(separatedBy: CharacterSet.alphanumerics.inverted).contains {
            let word = compact($0)
            return word.hasPrefix(name) && suffixes.contains(String(word.dropFirst(name.count)))
        }
    }

    /// Explicit dates use the message's date, not the day an old conversation is reopened.
    static func days(in text: String, relativeTo reference: Date, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        for (word, offset) in [("오늘", 0), ("내일", 1), ("모레", 2), ("어제", -1), ("그저께", -2)] where text.contains(word) {
            if let date = calendar.date(byAdding: .day, value: offset, to: reference) { dates.append(calendar.startOfDay(for: date)) }
        }
        if let regex = datePattern {
            let string = text as NSString
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let year = match.range(at: 1).location == NSNotFound ? calendar.component(.year, from: reference) : Int(string.substring(with: match.range(at: 1)))!
                let month = Int(string.substring(with: match.range(at: 2)))!, day = Int(string.substring(with: match.range(at: 3)))!
                if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                   calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day { dates.append(date) }
            }
        }
        if let regex = englishPattern {
            let string = text as NSString
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let month = englishMonths.firstIndex(of: string.substring(with: match.range(at: 1)).lowercased())! + 1
                let day = Int(string.substring(with: match.range(at: 2)))!
                let year = match.range(at: 3).location == NSNotFound ? calendar.component(.year, from: reference) : Int(string.substring(with: match.range(at: 3)))!
                if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                   calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day { dates.append(date) }
            }
        }
        let plain = text.replacingOccurrences(of: " ", with: "")
        let weekdays = ["월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일"]
        let namedDays = weekdays.indices.filter { plain.contains(weekdays[$0]) }
        let weekOffset = plain.contains("다음주") ? 1 : plain.contains("지난주") ? -1 : 0
        if !namedDays.isEmpty || ["이번주", "다음주", "지난주"].contains(where: plain.contains) {
            let today = calendar.startOfDay(for: reference)
            let weekday = (calendar.component(.weekday, from: reference) + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -weekday + weekOffset * 7, to: today)!
            for index in namedDays.isEmpty ? Array(0..<7) : namedDays {
                dates.append(calendar.date(byAdding: .day, value: index, to: monday)!)
            }
        }
        return dates
    }

    static func related(to body: String, at reference: Date, events: [CalendarEntry], calendar: Calendar = .current) -> [CalendarEntry] {
        let compactBody = compact(body)
        let dates = days(in: body, relativeTo: reference, calendar: calendar)
        let earliest = calendar.startOfDay(for: reference)
        let latest = calendar.date(byAdding: .day, value: 31, to: earliest)!
        var seen = Set<String>()
        return events.filter { event in
            guard !event.identifier.isEmpty, seen.insert(event.id).inserted else { return false }
            let matchesDay = dates.contains { day in
                event.start < calendar.date(byAdding: .day, value: 1, to: day)! && event.end > day
            }
            guard dates.isEmpty ? (event.end > earliest && event.start < latest) : matchesDay else { return false }
            // A location alone needs an explicit date as well; opening hours never identify an event.
            return mentions(event.title, in: body, compactText: compactBody) || (!dates.isEmpty && compact(event.location).count >= 3 && mentions(event.location, in: body, compactText: compactBody))
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
