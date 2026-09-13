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
        self.currentArtist = resolvedCurrentArtist
        self.currentTitle = resolvedCurrentTitle
        self.currentAlbum = resolvedCurrentAlbum
        self.currentYear = candidate.currentFileYear

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
            expectedFileSize: candidate.expectedFileSize,
            expectedMtime: candidate.expectedMtime,
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

/// One row in `AutoTaggerView`'s review list: a confidence chip, the
/// per-field current → proposed diffs with include toggles, a
/// Keep/Merge/Take title control, and a disclosure to pick a different
/// release. All state lives in `model` and `isConfirmed`, owned by the
/// parent view.
struct AutoTagReviewRow: View {
    let path: String
    let score: Double
    let isStrong: Bool
    @Binding var model: AutoTagRowModel
    @Binding var isConfirmed: Bool

    @State private var showReleasePicker: Bool = false

    /// Unlike the plain `$model.includeAlbum` binding, flipping this marks
    /// the toggle user-overridden — so a later `selectRelease` (picking a
    /// different release from `releaseDisclosure`) leaves the user's
    /// explicit choice alone instead of recomputing its automatic default.
    private var albumIncludeBinding: Binding<Bool> {
        Binding(
            get: { model.includeAlbum },
            set: { newValue in
                model.includeAlbum = newValue
                model.markAlbumToggleUserOverridden()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // E-A: an unavailable (nil) proposed artist renders as
            // current → current — a visible no-op, never an empty "→ "
            // overwrite — matching includeArtist's "never included" default.
            fieldDiff(name: "Artist", current: model.currentArtist, proposed: model.candidate.proposedArtist ?? model.currentArtist, include: $model.includeArtist)
            titleRow
            fieldDiff(name: "Album", current: model.currentAlbum, proposed: model.candidate.proposedAlbum, include: albumIncludeBinding)
            if model.candidate.proposedYear != nil {
                fieldDiff(
                    name: "Year",
                    current: model.currentYear.map(String.init) ?? "—",
                    proposed: model.candidate.proposedYear.map(String.init) ?? "—",
                    include: $model.includeYear
                )
            }
            releaseDisclosure
        }
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isConfirmed) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            confidenceChip
            Text((path as NSString).lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var confidenceChip: some View {
        Text("\(Int(score * 100))% \(isStrong ? "strong" : "weak")")
            .font(.caption2.smallCaps())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill((isStrong ? Color.green : Color.orange).opacity(0.18))
            )
            .foregroundStyle(isStrong ? Color.green : Color.orange)
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Title")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.tint)
                Picker("", selection: $model.titleChoice) {
                    Text("Keep").tag(TitleChoice.keep)
                    Text("Merge").tag(TitleChoice.merge)
                        .disabled(!isMergeAvailable)
                    Text("Take").tag(TitleChoice.take)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            Text("«\(model.resolvedTitle)»")
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
        }
    }

    private var isMergeAvailable: Bool {
        if case .baseMatch = model.titleTier {
            return true
        }
        return false
    }

    private func fieldDiff(name: String, current: String, proposed: String, include: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: include) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.smallCaps())
                    .foregroundStyle(.tint)
                HStack(spacing: 8) {
                    Text("«\(current)»")
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    Text("«\(proposed)»")
                        .foregroundStyle(.primary)
                }
                .font(.caption.monospaced())
            }
        }
    }

    @ViewBuilder
    private var releaseDisclosure: some View {
        if model.candidate.availableReleases.count > 1 {
            DisclosureGroup("Pick a different release…", isExpanded: $showReleasePicker) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.candidate.availableReleases, id: \.id) { release in
                        Button {
                            model.selectRelease(release)
                        } label: {
                            HStack {
                                Image(systemName: release.id == model.candidate.chosenRelease.id ? "largecircle.fill.circle" : "circle")
                                Text(releaseLabel(release))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.caption)
                .padding(.leading, 24)
                .padding(.top, 2)
            }
            .font(.caption)
        }
    }

    private func releaseLabel(_ release: MBRelease) -> String {
        let year = release.date.map { String($0.prefix(4)) } ?? "—"
        let country = release.country ?? "—"
        return "\(release.title) · \(year) · \(country)"
    }
}
