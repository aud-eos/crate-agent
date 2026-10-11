import Foundation

public struct OrganizeMetadataRequirements: Hashable, Sendable {
    public static let essential = OrganizeMetadataRequirements(template: "")
    private let fields: Set<SeratoMetadataField>

    public init(template: String) {
        fields = Set([SeratoMetadataField.artist, .title]).union(FilenameTemplateEngine.metadataFields(in: template))
    }

    func missingFields(in file: some HygieneFileSource) -> [SeratoMetadataField] {
        SeratoMetadataField.allCases.filter { field in
            fields.contains(field) && LibraryHygiene.isMissing(field.read(from: file))
        }
    }

    func validate(_ file: some HygieneFileSource) throws {
        let missing = missingFields(in: file)
        guard missing.isEmpty else { throw MissingMetadata(fields: missing) }
    }

    private struct MissingMetadata: LocalizedError {
        let fields: [SeratoMetadataField]
        var errorDescription: String? {
            "\(OrganizeMessages.needsMetadata(fields)) before organizing. Rescan after correcting the tags."
        }
    }
}
