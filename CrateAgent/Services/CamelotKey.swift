import Foundation

/// A key on the Camelot wheel: numbers 1–12, A for minor and B for major.
/// Parses musical (`Am`, `F#`, `Ab min`), Camelot (`8A`, `08a`) and Open Key (`1m`, `1d`) notation;
/// anything else is not a key, never a guess.
struct CamelotKey: Hashable, Comparable, Sendable {
    let number: Int
    let isMajor: Bool

    private static let numbers = 1 ... 12
    /// Camelot numbers of the major and minor keys on each pitch class, C = 0, from the Camelot wheel.
    private static let majorNumbers = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    private static let minorNumbers = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
    private static let naturalPitchClasses: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    private static let accidentals: [Character: Int] = ["#": 1, "♯": 1, "b": -1, "♭": -1]
    private static let majorSuffixes: Set<String> = ["", "maj", "major"]
    private static let minorSuffixes: Set<String> = ["m", "min", "minor"]

    init?(number: Int, isMajor: Bool) {
        guard Self.numbers.contains(number) else { return nil }
        self.number = number
        self.isMajor = isMajor
    }

    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = Self.wheel(trimmed) ?? Self.musical(trimmed) else { return nil }
        self = key
    }

    /// The keys that mix harmonically with this one: itself, one step either way round the wheel, and its relative.
    var compatibleKeys: Set<CamelotKey> {
        let wheelSize = Self.numbers.count
        let neighbours = [-1, 1].map { step in CamelotKey(unchecked: (number - 1 + step + wheelSize) % wheelSize + 1, isMajor: isMajor) }
        return Set(neighbours + [self, CamelotKey(unchecked: number, isMajor: !isMajor)])
    }

    var label: String {
        "\(number)\(isMajor ? "B" : "A")"
    }

    static func < (lhs: CamelotKey, rhs: CamelotKey) -> Bool {
        (lhs.number, lhs.isMajor ? 1 : 0) < (rhs.number, rhs.isMajor ? 1 : 0)
    }

    private init(unchecked number: Int, isMajor: Bool) {
        self.number = number
        self.isMajor = isMajor
    }

    /// Camelot (`8A`) or Open Key (`1m`), whose number maps to Camelot as `((openKey + 6) % 12) + 1`.
    private static func wheel(_ text: String) -> CamelotKey? {
        let digits = text.dropLast()
        guard let mode = text.last?.lowercased(), digits.allSatisfy({ character in character.isASCII && character.isNumber }),
              let value = Int(digits), numbers.contains(value)
        else { return nil }
        switch mode {
        case "a": return CamelotKey(number: value, isMajor: false)
        case "b": return CamelotKey(number: value, isMajor: true)
        case "m": return CamelotKey(number: (value + 6) % numbers.count + 1, isMajor: false)
        case "d": return CamelotKey(number: (value + 6) % numbers.count + 1, isMajor: true)
        default: return nil
        }
    }

    /// A root letter, an optional sharp or flat, then a major or minor suffix.
    private static func musical(_ text: String) -> CamelotKey? {
        guard let root = text.first.flatMap({ letter in naturalPitchClasses[Character(letter.uppercased())] }) else { return nil }
        var rest = text.dropFirst()
        var pitchClass = root
        if let accidental = rest.first.flatMap({ symbol in accidentals[symbol] }) {
            pitchClass += accidental
            rest = rest.dropFirst()
        }
        let suffix = rest.trimmingCharacters(in: .whitespaces).lowercased()
        let index = (pitchClass + majorNumbers.count) % majorNumbers.count
        if majorSuffixes.contains(suffix) {
            return CamelotKey(number: majorNumbers[index], isMajor: true)
        }
        if minorSuffixes.contains(suffix) {
            return CamelotKey(number: minorNumbers[index], isMajor: false)
        }
        return nil
    }
}
