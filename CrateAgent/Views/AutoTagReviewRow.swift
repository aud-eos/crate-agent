import SwiftUI

/// Per-file view-model behind one Auto-Tag review row. Plain struct, no
/// SwiftUI — this is the unit-tested half of the review UI
/// (`AutoTagReviewRowModelTests`); `AutoTagReviewRow` below is the thin
/// SwiftUI shell that renders it and is verified by build only.
///
/// Holds the "current" (pre-match) tag values alongside the resolved
/// `MatchCandidate` because `MatchCandidate` (Task 5) only carries the
/// *proposed* side of the diff — the current side lives on `FileRecord`
/// and is supplied by the caller (`AutoTaggerView`) at construction time.
struct AutoTagRowModel {
    private(set) var candidate: MatchCandidate
    let currentArtist: String
    let currentTitle: String
    let currentAlbum: String
    /// The "current" year shown in the review diff and used to default
    /// `includeYear`. Prefers `candidate.currentFileYear` — the file's
    /// on-disk tag, read at scan time — over the caller-supplied
    /// `tracks.year` fallback, since `tracks.year` is nil on a
    /// greenfield first-pass match (no `tracks` row exists yet), which
    /// used to make the diff show "— → 1994" even when the file already
    /// had a correct year tag.
    let currentYear: Int?

    /// The tier `TitleMatcher.decide` resolved for this row's title pair,
    /// fixed at construction — `titleChoice` may change, but the tier
    /// (and thus what `.merge` resolves to) does not.
    let titleTier: TitleTier

    var includeArtist: Bool
    var includeAlbum: Bool
    var includeYear: Bool
    var titleChoice: TitleChoice

    init(
        candidate: MatchCandidate,
        currentArtist: String,
        currentTitle: String,
        currentAlbum: String,
        currentYear: Int?
    ) {
        self.candidate = candidate
        self.currentArtist = currentArtist
        self.currentTitle = currentTitle
        self.currentAlbum = currentAlbum
        let resolvedCurrentYear = candidate.currentFileYear ?? currentYear
        self.currentYear = resolvedCurrentYear

        let decision = TitleMatcher.decide(current: currentTitle, proposed: candidate.proposedTitle)
        titleTier = decision.tier
        titleChoice = decision.defaultChoice

        includeArtist = candidate.proposedArtist != currentArtist
        includeAlbum = candidate.proposedAlbum != currentAlbum
        // A nil proposedYear means MusicBrainz had nothing to propose —
        // never defaults to "included" even though nil != resolvedCurrentYear.
        includeYear = candidate.proposedYear != nil && candidate.proposedYear != resolvedCurrentYear
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
    mutating func selectRelease(_ release: MBRelease) {
        candidate.chosenRelease = release
        candidate.proposedAlbum = release.title
    }

    /// Assembles the mutation payload: identity fields are always
    /// present (invariant #4 — the track link must never be partial),
    /// title is always resolved from `titleChoice` (there is no separate
    /// title toggle — `.keep` already means "no change"), and the
    /// remaining display fields are only included when their toggle is
    /// on. The release id comes from `candidate.chosenRelease`, so a
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
            artist: includeArtist ? candidate.proposedArtist : nil,
            title: resolvedTitle,
            album: includeAlbum ? candidate.proposedAlbum : nil,
            year: includeYear ? candidate.proposedYear : nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            fieldDiff(name: "Artist", current: model.currentArtist, proposed: model.candidate.proposedArtist, include: $model.includeArtist)
            titleRow
            fieldDiff(name: "Album", current: model.currentAlbum, proposed: model.candidate.proposedAlbum, include: $model.includeAlbum)
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
