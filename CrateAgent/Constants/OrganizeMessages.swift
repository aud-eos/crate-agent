enum OrganizeMessages {
    static let scanCancelled = "Scan cancelled. Previous preview retained."
    static let noValue = "—"

    static func needsMetadata(_ fields: [SeratoMetadataField]) -> String {
        "Needs \(fields.map(\.displayName).joined(separator: ", "))"
    }
}
