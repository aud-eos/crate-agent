import Foundation

struct WhitespacePreview: Equatable {
    let current: String
    let proposed: String

    static let legend = "· Space   ⇥ Tab   ↵ Line break   ⍽ Nonbreaking space   ␣ Other whitespace"

    var visibleCurrent: String {
        Self.visible(current)
    }

    var visibleProposed: String {
        Self.visible(proposed)
    }

    var summary: String {
        guard current != proposed else { return "No change" }
        if !current.isEmpty, current.allSatisfy(\.isWhitespace), proposed.isEmpty {
            return "Clear whitespace-only value"
        }
        let currentParts = Parts(current)
        let proposedParts = Parts(proposed)
        guard current.filter({ !$0.isWhitespace }) == proposed.filter({ !$0.isWhitespace }) else {
            let whitespaceChanged = current.filter(\.isWhitespace) != proposed.filter(\.isWhitespace)
            return whitespaceChanged ? "Change text and whitespace" : "Change text"
        }

        let leadingChanged = currentParts.leading != proposedParts.leading
        let trailingChanged = currentParts.trailing != proposedParts.trailing
        var descriptions: [String] = []
        if leadingChanged, trailingChanged, proposedParts.leading.isEmpty, proposedParts.trailing.isEmpty {
            let removed = currentParts.leading + currentParts.trailing
            descriptions.append("Remove leading and trailing \(Self.whitespaceName(removed))")
        } else {
            if leadingChanged {
                descriptions.append(Self.boundaryDescription("leading", current: currentParts.leading, proposed: proposedParts.leading))
            }
            if trailingChanged {
                descriptions.append(Self.boundaryDescription("trailing", current: currentParts.trailing, proposed: proposedParts.trailing))
            }
        }
        if currentParts.content != proposedParts.content {
            descriptions.append("Normalize internal whitespace")
        }
        return descriptions.enumerated().map { index, description in
            index == 0 ? description : description.prefix(1).lowercased() + description.dropFirst()
        }.joined(separator: "; ")
    }

    private static func boundaryDescription(_ position: String, current: String, proposed: String) -> String {
        proposed.isEmpty
            ? "Remove \(position) \(whitespaceName(current))"
            : "Change \(position) whitespace"
    }

    private static func whitespaceName(_ value: String) -> String {
        value.allSatisfy { $0 == " " } ? "spaces" : "whitespace"
    }

    private static func visible(_ value: String) -> String {
        guard !value.isEmpty else { return "Empty" }
        return value.map { character in
            switch character {
            case " ": "·"
            case "\t": "⇥"
            case "\r\n", "\r", "\n", "\u{2028}", "\u{2029}": "↵"
            case "\u{00a0}": "⍽"
            default: character.isWhitespace ? "␣" : String(character)
            }
        }.joined()
    }

    private struct Parts {
        let leading: String
        let content: String
        let trailing: String

        init(_ value: String) {
            leading = String(value.prefix(while: \.isWhitespace))
            let remaining = value.dropFirst(leading.count)
            trailing = String(remaining.reversed().prefix(while: \.isWhitespace).reversed())
            content = String(remaining.dropLast(trailing.count))
        }
    }
}
