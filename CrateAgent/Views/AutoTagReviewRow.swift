import SwiftUI

/// Per-file view-model behind one Auto-Tag review row. Plain struct, no
/// SwiftUI — this is the unit-tested half of the review UI
/// (`AutoTagReviewRowModelTests`); `AutoTagReviewRow` below is the thin
/// SwiftUI shell that renders it and is verified by build only.
///
/// Holds the "current" (pre-match) tag values alongside the resolved
/// `MatchCandidate`. The current side is the file's ACTUAL on-disk embedded
/// tags — carried on the candidate as `currentFile*`, read from the file at
/// scan time — NOT Serato's `files`-row snapshot. The diff and the
/// include-toggle defaults are about what will change ON THE FILE, so the
/// file's tags (including their absence) are the source of truth; substituting
/// the DB snapshot would hide a genuinely-missing or wrong file tag.
struct AutoTagRowModel {
    private(set) var candidate: MatchCandidate
    let currentArtist: String
    let currentTitle: String
    let currentAlbum: String
    /// The "current" year shown in the review diff and used to default
    /// `includeYear` — the file's on-disk year tag (`candidate.currentFileYear`),
    /// or nil when the file has no year frame. Deliberately NOT backfilled from
    /// the canonical `tracks.year`: if the file tag is absent but the DB/track
    /// already holds the proposed year, backfilling would default `includeYear`
    /// off and leave the file's year unwritten (finding #3999974015).
    let currentYear: Int?

    /// The tier `TitleMatcher.decide` resolved for this row's title pair,
    /// fixed at construction — `titleChoice` may change, but the tier
    /// (and thus what `.merge` resolves to) does not.
    let titleTier: TitleTier

    var includeArtist: Bool
    var includeAlbum: Bool
    var includeYear: Bool
    var titleChoice: TitleChoice

    /// Set the first time the user (rather than `init`'s own automatic
    /// default) flips the album toggle — see the `includeAlbum` binding in
    /// `AutoTagReviewRow`, the only place this is set to `true`. Once true,
    /// a later `selectRelease` call must leave the user's choice alone
    /// (rather than recomputing `includeAlbum` from the newly-picked
    /// release) — see `selectRelease`.
    private(set) var didUserOverrideAlbum = false

    /// Marks the album toggle as user-overridden — called from the
    /// `includeAlbum` binding's `set` in `AutoTagReviewRow` whenever the
    /// user (not `init` or `selectRelease`'s automatic default) flips it.
    mutating func markAlbumToggleUserOverridden() {
        didUserOverrideAlbum = true
    }

    init(candidate: MatchCandidate) {
        self.candidate = candidate
        // The baseline is the file's ACTUAL on-disk embedded tag, read at scan
        // time. A nil `currentFile*` means the file has NO such tag — treated
        // as absent (""), never backfilled from Serato's DB snapshot. If the
        // file tag is wrong/blank/missing while Serato already equals the
        // MusicBrainz proposal, backfilling the DB value would default the
        // include-toggle OFF and leave the file tag unfixed, and would show an
        // inaccurate current→proposed diff (findings #3999114442, #3999974015).
        let resolvedCurrentArtist = candidate.currentFileArtist ?? ""
        let resolvedCurrentTitle = candidate.currentFileTitle ?? ""
        let resolvedCurrentAlbum = candidate.currentFileAlbum ?? ""
        currentArtist = resolvedCurrentArtist
        currentTitle = resolvedCurrentTitle
        currentAlbum = resolvedCurrentAlbum
        currentYear = candidate.currentFileYear

        let decision = TitleMatcher.decide(current: resolvedCurrentTitle, proposed: candidate.proposedTitle)
        titleTier = decision.tier
        titleChoice = decision.defaultChoice

        // E-A: a nil proposedArtist means MusicBrainz had no artist
        // credit to propose — never defaults to "included" even though
        // nil != resolvedCurrentArtist, mirroring includeYear below.
        includeArtist = candidate.proposedArtist != nil && candidate.proposedArtist != resolvedCurrentArtist
        includeAlbum = candidate.proposedAlbum != resolvedCurrentAlbum
        // A nil proposedYear means MusicBrainz had nothing to propose —
        // never defaults to "included" even though nil != currentFileYear.
        includeYear = candidate.proposedYear != nil && candidate.proposedYear != candidate.currentFileYear
    }

    /// The title string `titleChoice` currently resolves to — shown live
    /// in the review row as the user switches Keep / Merge / Take.
    var resolvedTitle: String {
        TitleMatcher.value(
            for: titleChoice,
            current: currentTitle,
            proposed: candidate.proposedTitle,
            tier: titleTier
        )
    }

    /// Updates the chosen release (and the album it proposes) without
    /// re-resolving the rest of the candidate — mirrors
    /// `MatchCandidate.chosenRelease`'s "follows chosenRelease" contract.
    ///
    /// Also recomputes `includeAlbum`'s automatic default against the
    /// newly-picked release's title — unless the user has explicitly
    /// overridden the toggle (`didUserOverrideAlbum`), in which case their
    /// choice is left alone even as they keep browsing releases. Without
    /// this, a release picked after the toggle's initial "titles matched,
    /// default off" resolution would silently write `album: nil` despite
    /// the user explicitly choosing a different release.
    mutating func selectRelease(_ release: MBRelease) {
        candidate.chosenRelease = release
        candidate.proposedAlbum = release.title
        if !didUserOverrideAlbum {
            includeAlbum = release.title != currentAlbum
        }
    }

    /// Assembles the mutation payload: identity fields are always
    /// present (invariant #4 — the track link must never be partial),
    /// title is omitted (`nil`) for `.keep` — E-K: passing the current
    /// title back as an "applied" value is NOT equivalent to "no
    /// change"; it overwrites the canonical `tracks.title` (and the
    /// user's cherry-picked `(Clean)/(Dirty)/(Radio Version)` flags) on
    /// every re-match even when the user chose Keep. `.merge`/`.take`
    /// resolve to the actual proposed/merged string, same as before.
    /// The remaining display fields are only included when their toggle
    /// is on. The release id comes from `candidate.chosenRelease`, so a
    /// "pick a different release" selection is reflected here.
    func payload() -> ApplyMusicBrainzMatchPayload {
        ApplyMusicBrainzMatchPayload(
            fileID: candidate.fileID,
            acoustID: candidate.acoustID,
            recordingMBID: candidate.recordingMBID,
            releaseMBID: candidate.chosenRelease.id,
            artistMBID: candidate.artistMBID,
            isrc: candidate.isrc,
            fingerprintHash: candidate.fingerprintHash,
            // The file's indexed identity at lookup time, so the mutation
            // can reject a candidate that went stale before Apply (D-A).
            expectedFileSize: candidate.expectedFreshness.fileSize,
            expectedMtime: candidate.expectedFreshness.mtime,
            expectedMtimeNanoseconds: candidate.expectedFreshness.mtimeNanoseconds,
            expectedInode: candidate.expectedFreshness.inode,
            artist: includeArtist ? candidate.proposedArtist : nil,
            title: titleChoice == .keep ? nil : resolvedTitle,
            album: includeAlbum ? candidate.proposedAlbum : nil,
            year: includeYear ? candidate.proposedYear : nil,
            // The file's real pre-match on-disk tags, so undo restores
            // (or clears) the exact prior embedded values — not the
            // canonical `tracks.year` / Serato-imported DB snapshot, which
            // are different fields (invariant #4, findings D-D).
            currentFileYear: candidate.currentFileYear,
            currentFileArtist: candidate.currentFileArtist,
            currentFileTitle: candidate.currentFileTitle,
            currentFileAlbum: candidate.currentFileAlbum
        )
    }
}

struct AutoTagReviewRow: View {
    let path: String
    let assessment: RecordingMatchAssessment?
    @Binding var model: AutoTagRowModel
    @Binding var isConfirmed: Bool
    let canChooseRecording: Bool
    let onChooseRecording: () -> Void
    var isFocused = false
    var isReadOnly = false
    var isApplied = false

    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @State private var showUnchanged = false
    @State private var showReleasePicker = false

    init(path: String, assessment: RecordingMatchAssessment?, model: Binding<AutoTagRowModel>, isConfirmed: Binding<Bool>, canChooseRecording: Bool, onChooseRecording: @escaping () -> Void, isFocused: Bool = false, isReadOnly: Bool = false, isApplied: Bool = false) {
        self.path = path
        self.assessment = assessment
        _model = model
        _isConfirmed = isConfirmed
        self.canChooseRecording = canChooseRecording
        self.onChooseRecording = onChooseRecording
        self.isFocused = isFocused
        self.isReadOnly = isReadOnly
        self.isApplied = isApplied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isFocused ? density.spacing * 1.5 : density.spacing) {
            TrackHeading(
                artist: model.currentArtist.isEmpty ? model.candidate.proposedArtist : model.currentArtist,
                title: model.currentTitle.isEmpty ? model.candidate.proposedTitle : model.currentTitle,
                filename: (path as NSString).lastPathComponent,
                prominent: isFocused
            )
            .help(path)
            matchExplanation
            ViewThatFits(in: .horizontal) {
                HStack {
                    approval
                    Spacer()
                    recordingButton
                }
                VStack(alignment: .leading, spacing: density.detailSpacing) {
                    approval
                    recordingButton
                }
            }
            Divider()
            ForEach(ReviewField.allCases.filter { !isUnchanged($0) }) { field in
                fieldEditor(field)
            }
            if ReviewField.allCases.contains(where: isUnchanged) {
                DisclosureGroup("Show unchanged fields", isExpanded: $showUnchanged) {
                    VStack(alignment: .leading, spacing: density.spacing) {
                        ForEach(ReviewField.allCases.filter { isUnchanged($0) }) { field in
                            fieldEditor(field)
                        }
                    }
                    .padding(.top, density.detailSpacing)
                }
            }
            releaseDisclosure
        }
        .padding(.vertical, density.rowPadding)
    }

    @ViewBuilder
    private var approval: some View {
        if !isApplied {
            Toggle("Approved for Apply", isOn: $isConfirmed)
                .toggleStyle(.checkbox)
                .disabled(isReadOnly)
                .help("Approval stages this proposal. Apply approved tracks writes the changes.")
        }
    }

    private var recordingButton: some View {
        Button("Choose recording…", action: onChooseRecording)
            .disabled(!canChooseRecording)
            .help(model.candidate.evidence.isMetadataSearch
                ? "Inspect the recordings found by the artist/title search. Changing recording resets field and release choices."
                : "Inspect the recordings returned by this audio lookup. Changing recording resets field and release choices.")
    }

    @ViewBuilder
    private var matchExplanation: some View {
        if case let .metadataSearch(textScore) = model.candidate.evidence {
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                Text("Text match: \(Int((textScore * 100).rounded()))%")
                    .font(.headline)
                    .help(AutoTagMessages.metadataScoreHelp)
                Label {
                    Text(AutoTagMessages.metadataCandidateNotice)
                } icon: {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            fingerprintExplanation
        }
    }

    private var fingerprintExplanation: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            Text("Audio match: \(Int(((assessment?.score ?? model.candidate.score) * 100).rounded()))%")
                .font(.headline)
                .help("AcoustID fingerprint score, not a probability that these tags or this release are correct. Recording IDs from the same result share its score.")
            if assessment?.hasMultiplePlausibleRecordings == true {
                Label {
                    Text("Multiple plausible recordings — review recording choice")
                } icon: {
                    Image(systemName: "square.stack").foregroundStyle(.orange)
                }
            }
            if assessment?.isBelowStrongThreshold == true {
                Label {
                    Text("Lower audio match — review carefully")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } else if assessment?.isBulkApprovalEligible == true {
                Label("Suggested match — check the version and release", systemImage: "waveform")
            } else if assessment == nil {
                Label("Review recording choice", systemImage: "questionmark.circle")
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum ReviewField: String, CaseIterable, Identifiable {
        case artist, title, album, year
        var id: String {
            rawValue
        }
    }

    private func isUnchanged(_ field: ReviewField) -> Bool {
        switch field {
        case .artist: model.candidate.proposedArtist == model.currentArtist
        case .title: model.candidate.proposedTitle == model.currentTitle
        case .album: model.candidate.proposedAlbum == model.currentAlbum
        case .year: model.candidate.proposedYear == model.currentYear && model.candidate.proposedYear != nil
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: ReviewField) -> some View {
        switch field {
        case .artist:
            fieldDiff(name: "Artist", current: model.currentArtist, proposed: model.candidate.proposedArtist, include: $model.includeArtist)
        case .title:
            titleEditor
        case .album:
            fieldDiff(name: "Album", current: model.currentAlbum, proposed: model.candidate.proposedAlbum, include: albumIncludeBinding)
        case .year:
            fieldDiff(name: "Year", current: model.currentYear.map(String.init), proposed: model.candidate.proposedYear.map(String.init), include: $model.includeYear)
        }
    }

    private var albumIncludeBinding: Binding<Bool> {
        Binding(
            get: { model.includeAlbum },
            set: { newValue in
                var edited = model
                edited.includeAlbum = newValue
                edited.markAlbumToggleUserOverridden()
                model = edited
            }
        )
    }

    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            MetadataComparison(current: model.currentTitle, proposed: model.candidate.proposedTitle, field: "Title", prominent: isFocused)
            Picker("Title choice", selection: $model.titleChoice) {
                Text("Keep current").tag(TitleChoice.keep)
                Text("Merge").tag(TitleChoice.merge).disabled(!isMergeAvailable)
                Text("Use suggestion").tag(TitleChoice.take)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isReadOnly || isApplied)
            .frame(maxWidth: 460)
            savedValue(model.resolvedTitle)
        }
    }

    private var isMergeAvailable: Bool {
        if case .baseMatch = model.titleTier {
            return true
        }
        return false
    }

    private func fieldDiff(name: String, current: String?, proposed: String?, include: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            MetadataComparison(current: current, proposed: proposed ?? "Unavailable from MusicBrainz", field: name, prominent: isFocused)
            Toggle("Apply suggestion", isOn: include)
                .toggleStyle(.checkbox)
                .disabled(proposed == nil || isReadOnly || isApplied)
                .accessibilityLabel("Apply suggested \(name.lowercased())")
            savedValue(include.wrappedValue && proposed != nil ? proposed : current)
        }
    }

    private func savedValue(_ value: String?) -> some View {
        Text("\(isApplied ? "Reviewed result" : "Will save"): \(value.flatMap { $0.isEmpty ? nil : $0 } ?? "Not set")")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var releaseDisclosure: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            Text("Release: \(releaseLabel(model.candidate.chosenRelease))")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if model.candidate.availableReleases.count > 1 {
                DisclosureGroup("Choose release…", isExpanded: $showReleasePicker) {
                    LazyVStack(alignment: .leading, spacing: density.detailSpacing) {
                        ForEach(model.candidate.availableReleases, id: \.id) { release in
                            Button {
                                guard release.id != model.candidate.chosenRelease.id else { return }
                                model.selectRelease(release)
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: release.id == model.candidate.chosenRelease.id ? "largecircle.fill.circle" : "circle")
                                    Text(releaseLabel(release))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, density.detailSpacing)
                            }
                            .buttonStyle(.plain)
                            .disabled(isReadOnly || isApplied)
                            .accessibilityLabel("\(release.id == model.candidate.chosenRelease.id ? "Selected release" : "Choose release"): \(releaseLabel(release))")
                        }
                    }
                }
            }
        }
    }

    private func releaseLabel(_ release: MBRelease) -> String {
        let year = release.date.map { String($0.prefix(4)) } ?? "Year unknown"
        let country = release.country ?? "Country unknown"
        return "\(release.title) · \(year) · \(country)"
    }
}
