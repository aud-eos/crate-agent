import Foundation

/// Beets-compatible filename template renderer. Templates use the
/// `$field` syntax referenced in the design plan / Beets docs
/// (https://beets.readthedocs.io/en/stable/reference/pathformat.html).
///
/// Per Invariant 6, the template covers the *filename* portion only.
/// The directory portion (`<MusicFolder>/<Letter>/`) is fixed by the
/// `ArtistLetterNormalizer`; the user can't reconfigure it in SP-1.
///
/// Field set (matches `SeratoMetadata` plus the file extension):
///   `$artist`, `$title`, `$album`, `$genre`, `$bpm`, `$key`,
///   `$comment`, `$label`, `$length`, `$ext`
///
/// SP-1 deliberately keeps the syntax narrow: no function calls,
/// no nested expressions. Variables resolve to "" when the underlying
/// metadata field is nil — the engine never throws on missing data,
/// the caller handles the "empty filename" outcome.
public enum FilenameTemplateEngine {
    /// Filesystem-illegal characters on macOS / common cross-platform
    /// targets. Replaced with `_` in field substitutions so a slash
    /// in `$title` can't escape the intended folder.
    static let illegalCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "/\\:*?\"<>|")
        // Control characters break Finder display and cause name
        // mangling on some filesystems — strip them all.
        set.formUnion(.controlCharacters)
        return set
    }()

    /// Render `template` against the supplied metadata + extension.
    /// `extension` does NOT include the leading dot.
    public static func render(
        template: String,
        metadata: SeratoMetadata,
        fileExtension: String
    ) -> String {
        substituteFields(in: template) { identifier in
            substitute(identifier: identifier, metadata: metadata, fileExtension: fileExtension)
        }
    }

    static func metadataFields(in template: String) -> Set<SeratoMetadataField> {
        var fields: Set<SeratoMetadataField> = []
        _ = substituteFields(in: template) { identifier in
            if let field = metadataFieldsByIdentifier[identifier] {
                fields.insert(field)
            }
            return ""
        }
        return fields
    }

    private static let metadataFieldsByIdentifier = Dictionary(uniqueKeysWithValues: SeratoMetadataField.allCases.map { field in
        (field == .musicalKey ? "key" : field.rawValue, field)
    })

    private static func substituteFields(in template: String, resolve: (String) -> String) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            let char = template[index]
            if char == "$" {
                let after = template.index(after: index)
                if after < template.endIndex && template[after] == "$" {
                    // Literal `$$` -> `$`. Matches Beets / shell convention.
                    output.append("$")
                    index = template.index(after: after)
                    continue
                }
                let (identifier, advancedIndex) = readIdentifier(in: template, from: after)
                output.append(resolve(identifier))
                index = advancedIndex
                continue
            }
            output.append(char)
            index = template.index(after: index)
        }
        return output
    }

    // MARK: - Internals (testable)

    /// Read an identifier starting at `start`. Identifiers are ASCII
    /// alphanumerics + underscore. Returns the identifier (possibly
    /// empty if the `$` was unfollowed by a name) and the index just
    /// past it.
    static func readIdentifier(
        in template: String,
        from start: String.Index
    ) -> (String, String.Index) {
        var index = start
        var identifier = ""
        while index < template.endIndex {
            let char = template[index]
            if char.isASCII, char.isLetter || char.isNumber || char == "_" {
                identifier.append(char)
                index = template.index(after: index)
            } else {
                break
            }
        }
        return (identifier, index)
    }

    /// Look up `identifier`, sanitize its value, and return the result.
    /// Unknown identifiers render as empty — same as Beets' default
    /// behavior when a field doesn't exist on the track.
    static func substitute(
        identifier: String,
        metadata: SeratoMetadata,
        fileExtension: String
    ) -> String {
        if identifier == "ext" {
            return sanitize(fileExtension)
        }
        guard let field = metadataFieldsByIdentifier[identifier] else { return "" }
        let rawValue: String?
        switch field {
        case .artist: rawValue = metadata.artist
        case .title: rawValue = metadata.title
        case .album: rawValue = metadata.album
        case .genre: rawValue = metadata.genre
        case .bpm: rawValue = metadata.bpm
        case .musicalKey: rawValue = metadata.musicalKey
        case .comment: rawValue = metadata.comment
        case .label: rawValue = metadata.label
        case .length: rawValue = metadata.length
        }
        return sanitize(rawValue ?? "")
    }

    /// Replace any filesystem-illegal character with `_`. Whitespace
    /// is preserved because users care about it for readability
    /// (e.g., "Artist - Title.mp3"); only structurally-illegal
    /// characters get replaced.
    static func sanitize(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Unicode.Scalar in
            illegalCharacters.contains(scalar) ? Unicode.Scalar("_") : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
