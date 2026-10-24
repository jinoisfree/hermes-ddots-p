import Foundation

struct PetIdentity: Equatable {
    static let defaultName = "태식이"
    static let settingsKey = "petName"
    static let maximumLength = 20
    let name: String

    static func normalized(_ input: String) -> String {
        input.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").precomposedStringWithCanonicalMapping
    }

    static func validationMessage(for input: String) -> String? {
        let name = normalized(input)
        if name.isEmpty { return "펫 이름을 입력해 주세요." }
        if name.count > maximumLength { return "이름은 \(maximumLength)자까지 입력할 수 있어요." }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\u{200D}" }) {
            return "표시할 수 있는 문자로 이름을 입력해 주세요."
        }
        return nil
    }

    static func load(from defaults: UserDefaults = .standard) -> PetIdentity {
        let saved = defaults.string(forKey: settingsKey) ?? defaultName
        return PetIdentity(name: validationMessage(for: saved) == nil ? normalized(saved) : defaultName)
    }

    func save(to defaults: UserDefaults = .standard) { defaults.set(name, forKey: Self.settingsKey) }

    private var hasFinalConsonant: Bool {
        guard let scalar = name.unicodeScalars.last, (0xAC00...0xD7A3).contains(scalar.value) else { return false }
        return (scalar.value - 0xAC00) % 28 != 0
    }
    var subject: String { name + (hasFinalConsonant ? "이" : "가") }
    var greeting: String { name + (hasFinalConsonant ? "과" : "와") + " 함께" }
    var idleHeadline: String { "헤헤헹" }
    var dozeHeadline: String { "나 자는거 아니다" }
    var dashboardIntroduction: String { "AI가 일하는 동안, \(subject) 살펴볼게요." }
    var dashboardTitle: String { "ddots · \(name) · AI 작업" }
}
