import Foundation

/// Copy for the Library's still-needs checklist, its chips and the genre, BPM and key filters.
enum LibraryChecklistMessages {
    static let stillNeedsColumn = "Still needs"
    static let dateAddedColumn = "Date added"
    static let myPlaysColumn = "My plays"
    static let unknown = "unknown"
    static let keeperTag = "Keeper"
    static let finishedTag = "Finished"
    static let unreadable = "Checklist unreadable"
    static let dateAddedFromSerato = "From Serato"
    static let dateAddedFirstIndexed = "First indexed by crate-agent"
    static let neverPlayedUnavailable = "Waiting for Serato History. Close Serato to read play counts."
    static let markKeeper = "Mark as Keeper"
    static let clearKeeper = "Clear Keeper"
    static let chipBarLabel = "Checklist filters"
    static let countLoading = "…"
    static let finishedHelp = "Nothing left to do for this file."
    static let keeperMenuHelp = "A keeper counts as Finished, with every encoding of its recording. It changes no Serato file. Undo it from History."
    static let noMatches = "No matching tracks"
    static let clearToSeeMore = "Clear the search, checklist chip or filters to see more tracks."
    static let keeperHelp = "Marked as a keeper: it counts as Finished, and its other encodings do too."

    static func chipTitle(_ chip: ChecklistChip) -> String {
        switch chip {
        case .needsWork: "Needs work"
        case .notInCrate: "Not in a crate"
        case .noCues: "No cues"
        case .gridUnchecked: "Grid unchecked"
        case .lowQuality: "Low quality"
        case .neverPlayed: "Never played"
        case .tooManyVersions: "Too many versions"
        case .finished: "Finished"
        }
    }

    static func chipHelp(_ chip: ChecklistChip) -> String {
        switch chip {
        case .needsWork: "Files that still need something, or whose checklist isn't fully known yet."
        case .notInCrate: "Files in no Serato crate. SmartCrates don't count."
        case .noCues: "Files whose Serato data has no cue points."
        case .gridUnchecked: "Files whose beatgrid isn't locked in Serato."
        case .lowQuality: "Lossy files below \(LibraryChecklist.minimumLossyBitrateKbps) kbps."
        case .neverPlayed: "Files Serato History has no play of."
        case .tooManyVersions: "Non-main versions of song families with more than \(LibraryChecklist.maximumFamilyVersions) versions."
        case .finished: "Files that need nothing more, and keepers."
        }
    }

    static func chipLabel(_ chip: ChecklistChip, count: Int?) -> String {
        "\(chipTitle(chip)) \(count?.formatted() ?? countLoading)"
    }

    static func unavailableNote(_ reason: String) -> String {
        "\(chipTitle(.neverPlayed)): \(reason)"
    }

    static func neverPlayedFailed(_ reason: String) -> String {
        "Couldn't read Serato History: \(reason)"
    }

    static func chipAccessibilityLabel(_ chip: ChecklistChip, count: Int?) -> String {
        guard let count else { return "\(chipTitle(chip)), count loading" }
        return count == 1 ? "\(chipTitle(chip)), 1 file" : "\(chipTitle(chip)), \(count.formatted()) files"
    }

    static func tag(_ item: ChecklistItem) -> String {
        switch item {
        case .inCrate: "Crate"
        case .cuePoints: "Cues"
        case .beatgridChecked: "Grid"
        case .metadata: "Tags"
        case .quality: "Quality"
        case .versions: "Versions"
        case .duplicate: "Duplicate"
        }
    }

    static func unknownTag(_ item: ChecklistItem) -> String {
        "\(tag(item)) \(unknown)"
    }

    static func familyFilesNeedingWork(_ needing: Int, of total: Int) -> String {
        "\(needing) of \(total) files need work"
    }

    static let tagSeparator = " · "

    /// One sentence naming the fix for a failing item.
    static func failingHelp(_ item: ChecklistItem, missing: Set<MetadataField>, beatgridMarkerCount: Int?, bitrateKbps: Int?) -> String {
        switch item {
        case .inCrate: "Not in a crate: add it to a crate in Serato."
        case .cuePoints: "No cues: set cue points in Serato."
        case .beatgridChecked:
            beatgridMarkerCount == 0 ? "No beatgrid: analyze it in Serato, then lock the beatgrid." : "Grid unchecked: lock the beatgrid in Serato."
        case .metadata: metadataHelp(missing)
        case .quality: "Low quality\(bitrateKbps.map { bitrate in " (\(bitrate) kbps)" } ?? ""): replace it with a lossless copy or one of at least "
            + "\(LibraryChecklist.minimumLossyBitrateKbps) kbps."
        case .versions: "Too many versions: its song family has more than \(LibraryChecklist.maximumFamilyVersions); remove filler or mark this one as a keeper."
        case .duplicate: "Duplicate: a confirmed copy of another file; remove the extra copy or mark this one as a keeper."
        }
    }

    /// One sentence saying why an item isn't known yet.
    static func unknownHelp(_ item: ChecklistItem) -> String {
        switch item {
        case .inCrate: "Crate unknown: crate-agent reads Serato's crates after a sync while Serato is closed."
        case .cuePoints: "Cues unknown: this file's Serato data hasn't been read yet or couldn't be read; Workers lists the reason."
        case .beatgridChecked: "Grid unknown: Serato's database has no beatgrid lock for this file yet."
        case .quality: "Quality unknown: the bitrate of this lossy file isn't known."
        case .metadata, .versions, .duplicate: "\(unknownTag(item))."
        }
    }

    private static func metadataHelp(_ missing: Set<MetadataField>) -> String {
        var sentences: [String] = []
        let identity = [MetadataField.artist, .title].filter(missing.contains)
        if !identity.isEmpty {
            sentences.append("Missing \(fieldList(identity)): fix it through Auto-Tag.")
        }
        if missing.contains(.genre) {
            sentences.append("Missing genre: set it in your tag editor.")
        }
        let analysis = [MetadataField.bpm, .key].filter(missing.contains)
        if !analysis.isEmpty {
            sentences.append("Missing \(fieldList(analysis)): use Analyze in Serato.")
        }
        return sentences.joined(separator: " ")
    }

    private static func fieldList(_ fields: [MetadataField]) -> String {
        fields.map { field in
            switch field {
            case .artist: "artist"
            case .title: "title"
            case .genre: "genre"
            case .bpm: "BPM"
            case .key: "key"
            }
        }.joined(separator: " and ")
    }

    // MARK: - Facets

    static let anyValue = "Any"
    static let genreMenuTitle = "Genre"
    static let keyMenuTitle = "Key"
    static let anyGenre = "Any genre"
    static let anyKey = "Any key"
    static let loadingOptions = "Loading…"
    static let noGenres = "No genres in this view"
    static let noKeys = "No readable keys in this view"
    static let bpmFrom = "BPM from"
    static let bpmTo = "BPM to"
    static let clearFilters = "Clear filters"
    static let clearFiltersHelp = "Clear the genre, BPM and key filters."
    static let facetHelp = "Counts cover every file in the chosen library status, before search and other filters."
    static let bpmHelp = "An inclusive BPM range. Files with no BPM never match. Press Return to apply."
    static let bpmNotNumber = "Enter BPM as a number, such as 124 or 124.5."
    static let bpmNegative = "BPM can't be negative."
    static let bpmReversed = "The lower BPM must not be above the upper one."
    static let facetBarLabel = "Genre, BPM and key filters"

    static func genreLabel(first: String?, others: Int) -> String {
        guard let first else { return "\(genreMenuTitle): \(anyValue)" }
        return others > 0 ? "\(genreMenuTitle): \(first) +\(others)" : "\(genreMenuTitle): \(first)"
    }

    static func keyLabel(_ key: CamelotKey?) -> String {
        key.map { key in "\(keyMenuTitle): compatible with \(key.label)" } ?? "\(keyMenuTitle): \(anyValue)"
    }

    static let keyHelp = "Matches the chosen key, one step either way on the Camelot wheel, and its relative major or minor. "
        + "Keys in any notation count; unreadable keys never match."

    static func keyOption(_ key: CamelotKey, spellings: Set<String>) -> String {
        let stored = spellings.sorted().joined(separator: ", ")
        return stored == key.label ? key.label : "\(key.label) (\(stored))"
    }

    static func genreOption(_ option: GenreOption) -> String {
        "\(option.value) (\(option.count.formatted()))"
    }

    // MARK: - Workers

    static let duplicatesTitle = "Duplicate checklist"
    static let duplicatesNotRefreshed = "Not checked yet."
    static let duplicatesRefreshing = "Checking confirmed duplicate groups…"
    static let duplicatesExplanation = "Flags members of confirmed duplicate groups from cached digests, with no new scan. "
        + "Needs-listening groups and files marked as keepers aren't flagged."

    static func duplicatesRefreshed(_ count: Int) -> String {
        count == 1 ? "1 file is in a confirmed duplicate group." : "\(count.formatted()) files are in confirmed duplicate groups."
    }

    static func duplicatesFailed(_ reason: String) -> String {
        "Could not check duplicates; the Duplicate tags shown are older. \(reason)"
    }
}
