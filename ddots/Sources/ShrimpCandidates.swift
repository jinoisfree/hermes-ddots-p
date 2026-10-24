import Foundation
import SwiftUI

/// Display attributes only. The original body and command labels are never rewritten.
enum ShrimpCandidates {
    struct Candidate: Codable, Equatable {
        let number: Int
        let file: String
        let folder: String
        let location: String
    }
    struct Span { let range: NSRange; let kind: Int }
    static func scan(_ text: String) -> ([Candidate], [Span]) {
        var candidates: [Candidate] = [], spans: [Span] = [], offset = 0
        func match(_ pattern: String, _ line: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
            return (0..<m.numberOfRanges).map { (line as NSString).substring(with: m.range(at: $0)) }
        }
        for block in text.components(separatedBy: "\n\n") {
            defer { offset += (block as NSString).length + 2 }
            let lines = block.components(separatedBy: "\n")
            guard let first = lines.first else { continue }
            var folder = "", start = 1
            if lines.count > 1 && lines[1].hasPrefix("   ") { folder = String(lines[1].dropFirst(3)); start = 2 }
            if let m = match("^(\\d+)\\. (?!→ )(.+)$", first), lines.count == start {
                guard (m[2] as NSString).pathExtension.count > 0 else { continue }
                candidates.append(Candidate(number: Int(m[1])!, file: m[2], folder: folder, location: ""))
                // The number is set apart from the name, which may itself start with one ("5. 8. 메모.md").
                let number = (m[1] as NSString).length + 1
                spans.append(Span(range: NSRange(location: offset, length: number), kind: 2))
                spans.append(Span(range: NSRange(location: offset + number + 1, length: (m[2] as NSString).length), kind: 0))
            } else {
                guard (first as NSString).pathExtension.count > 0, lines.count > start else { continue }
                let rows = lines[start...].map { match("^(\\d+)\\. → (.+)$", $0) }
                guard rows.allSatisfy({ $0 != nil }) else { continue }
                spans.append(Span(range: NSRange(location: offset, length: (first as NSString).length), kind: 0))
                var rowOffset = offset + lines.prefix(start).reduce(0) { $0 + ($1 as NSString).length + 1 }
                for (line, row) in zip(lines[start...], rows) {
                    let m = row!
                    candidates.append(Candidate(number: Int(m[1])!, file: first, folder: folder, location: m[2]))
                    spans.append(Span(range: NSRange(location: rowOffset, length: (m[1] as NSString).length), kind: 0))
                    let last = m[2].components(separatedBy: " → ").last!
                    spans.append(Span(range: NSRange(location: rowOffset + (line as NSString).length - (last as NSString).length, length: (last as NSString).length), kind: 2))
                    let arrow = (line as NSString).range(of: "→")
                    spans.append(Span(range: NSRange(location: rowOffset + arrow.location, length: arrow.length), kind: 1))
                    rowOffset += (line as NSString).length + 1
                }
            }
            if !folder.isEmpty { spans.append(Span(range: NSRange(location: offset + (first as NSString).length + 1, length: (lines[1] as NSString).length), kind: 1)) }
        }
        if text.hasPrefix("선택: "), let first = text.components(separatedBy: "\n").first {
            let path = String(first.dropFirst(4)).components(separatedBy: " → ")[0]
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { spans.append(Span(range: NSRange(location: 4 + (path as NSString).length - (name as NSString).length, length: (name as NSString).length), kind: 0)) }
        }
        return (candidates, spans)
    }
    static func styled(_ text: String, trusted: Bool, accent: Color) -> AttributedString? {
        guard trusted else { return nil }
        let spans = scan(text).1
        guard !spans.isEmpty else { return nil }
        var result = AttributedString(text)
        for span in spans {
            guard let range = Range(span.range, in: text), let target = Range(range, in: result) else { continue }
            if span.kind == 1 {
                result[target].foregroundColor = .secondary
                result[target].font = .system(size: ChatMetrics.bodyFont - 1)
            } else {
                result[target].font = .system(size: ChatMetrics.bodyFont, weight: .bold)
                if span.kind == 0 { result[target].foregroundColor = accent }
            }
        }
        return result
    }
}

/// Wire records are parsed only after the caller has checked the bot sender.
struct ShrimpPage: Equatable {
    let current: Int
    let pages: Int
    let total: Int
    static func parse(_ text: String) -> ShrimpPage? {
        let pattern = "^쪽 ([0-9]+)/([0-9]+) · 총 ([0-9]+)건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다$"
        guard let r = try? NSRegularExpression(pattern: pattern), let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Int((text as NSString).substring(with: m.range(at: 1))), let b = Int((text as NSString).substring(with: m.range(at: 2))),
              let c = Int((text as NSString).substring(with: m.range(at: 3))), a > 0, a <= b, b > 1, c > 10, (c + 9) / 10 == b else { return nil }
        return ShrimpPage(current: a, pages: b, total: c)
    }
    var numbers: [Int] { Array(Set([1, pages] + Array(max(1,current-2)...min(pages,current+2)))).sorted() }
}
struct ShrimpAllHeader: Equatable {
    let part: Int
    let parts: Int
    let total: Int
    static func parse(_ text: String) -> ShrimpAllHeader? {
        let first = text.components(separatedBy: "\n").first ?? ""
        guard let r = try? NSRegularExpression(pattern: "^전체 목록 ([0-9]+)/([0-9]+) · 총 ([0-9]+)건$"),
              let m = r.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
              let a = Int((first as NSString).substring(with: m.range(at: 1))), let b = Int((first as NSString).substring(with: m.range(at: 2))),
              let c = Int((first as NSString).substring(with: m.range(at: 3))), a > 0, a <= b, b <= 300, c > 0, c <= 300 else { return nil }
        return ShrimpAllHeader(part: a, parts: b, total: c)
    }
}

enum ShrimpListSearch {
    static func filter(_ candidates: [ShrimpCandidates.Candidate], query: String) -> [ShrimpCandidates.Candidate] {
        func normalized(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
        let words = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return candidates }
        return candidates.filter { item in
            let text = normalized([item.file, item.folder, item.location].joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }
    }
}

struct ShrimpListPane: View {
    let candidates: [ShrimpCandidates.Candidate]
    let choose: (Int) -> Void
    let close: () -> Void
    var collapsed = false
    var toggle: () -> Void = {}
    @Binding var page: Int
    @Binding var query: String
    var searchFocus: (Bool) -> Void = { _ in }
    var dragArea = AnyView(EmptyView())
    @FocusState private var searching: Bool
    private var filtered: [ShrimpCandidates.Candidate] { ShrimpListSearch.filter(candidates, query: query) }
    private var pages: Int { max(1, (filtered.count + 24) / 25) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack {
                    Text("전체 목록 \(candidates.count)건").font(.headline)
                    Spacer()
                }.contentShape(Rectangle()).onTapGesture(count: 2, perform: toggle)
                    // The title moves the whole window, as the conversation's header does; a double-click still folds the list.
                    .overlay(dragArea)
                    .accessibilityIdentifier("shrimp-list-title")
                Button(action: close) { Image(systemName: "xmark") }.help("전체 목록 닫기")
            }
            if !collapsed {
            HStack {
                TextField("목록 안에서 검색", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("shrimp-list-search").focused($searching)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.help("검색어 지우기") }
            }
            Text("\(filtered.count)건").font(.caption).foregroundColor(.secondary)
            ScrollView(.horizontal) {
                HStack { ForEach(1...pages, id: \.self) { n in
                    Button("\(n)") { page = n }.buttonStyle(.bordered).tint(n == page ? .accentColor : .secondary)
                } }
            }
            if filtered.isEmpty { Text(candidates.isEmpty ? "목록을 기다리고 있어요. 만료된 목록은 다시 검색해 주세요." : "일치하는 항목이 없어요.").foregroundColor(.secondary) }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(filtered.dropFirst((min(page,pages)-1)*25).prefix(25)), id: \.number) { item in
                        Button { choose(item.number) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(item.number). \(item.file)").fontWeight(.bold).foregroundColor(.accentColor)
                                if !item.folder.isEmpty { Text(item.folder).font(.caption).foregroundColor(.secondary) }
                                if !item.location.isEmpty { Text("→ " + item.location).foregroundColor(.primary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).id(item.number)
                    }
                }
            }
            .onAppear { proxy.scrollTo(filtered.dropFirst((min(page,pages)-1)*25).first?.number, anchor: .top) }
            .onChange(of: page) { _ in proxy.scrollTo(filtered.dropFirst((min(page,pages)-1)*25).first?.number, anchor: .top) }
            .onChange(of: candidates) { _ in proxy.scrollTo(filtered.dropFirst((min(page,pages)-1)*25).first?.number, anchor: .top) }
            }
            }
        }.padding(14).onChange(of: candidates) { _ in page = min(page,pages) }
            .onChange(of: query) { _ in page = 1 }
            .onChange(of: searching, perform: searchFocus)
            .onDisappear { searchFocus(false) }
    }
}
