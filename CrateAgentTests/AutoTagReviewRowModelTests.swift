@testable import CrateAgent
import XCTest

/// Unit tests for `AutoTagRowModel` — the plain, no-SwiftUI view-model
/// behind the Auto-Tag review row. Exercises payload assembly only;
/// the SwiftUI layer (`AutoTagReviewRow`, `AutoTaggerView`) is verified
/// by build, not by these tests.
///
/// The model's current-tag baseline comes entirely from the candidate's
/// on-disk snapshot (`currentFile*`), so the fixtures set those fields to
/// express "what the file currently has" (findings #3999114442 / #3999974015).
final class AutoTagReviewRowModelTests: XCTestCase {
    // MARK: - Fixtures

    private func makeRelease(
        id: String = "release-1",
        title: String = "Test Album",
        date: String? = "1994",
        country: String? = "US"
    ) -> MBRelease {
        MBRelease(id: id, title: title, date: date, country: country, status: "Official")
    }

    private func makeCandidate(
        proposedArtist: String? = "Test Artist",
        proposedTitle: String = "Test Title",
        proposedAlbum: String = "Test Album",
        proposedYear: Int? = 1994,
        chosenRelease: MBRelease? = nil,
        availableReleases: [MBRelease]? = nil,
        currentFileYear: Int? = nil,
        currentFileArtist: String? = nil,
        currentFileTitle: String? = nil,
        currentFileAlbum: String? = nil
    ) -> MatchCandidate {
        let release = chosenRelease ?? makeRelease()
        return MatchCandidate(
            fileID: 1,
            evidence: .fingerprint(acoustID: "acoustid-1", score: 0.95),
            recordingMBID: "recording-1",
            artistMBID: "artist-1",
            fingerprintHash: Data([0xAB, 0xCD, 0xEF]),
            expectedFileSize: 1000,
            expectedMtime: 42,
            chosenRelease: release,
            availableReleases: availableReleases ?? [release],
            isrc: "ISRC0000001",
            proposedArtist: proposedArtist,
            proposedTitle: proposedTitle,
            proposedAlbum: proposedAlbum,
            proposedYear: proposedYear,
            currentFileYear: currentFileYear,
            currentFileArtist: currentFileArtist,
            currentFileTitle: currentFileTitle,
            currentFileAlbum: currentFileAlbum
        )
    }

    // MARK: - Title choice drives the title value; toggles gate the rest

    func testPayloadHonorsFieldTogglesAndTitleChoice() {
        // "Foo Song Title [DJ foobar remix - radio version]" vs proposed
        // "Foo Song Title" is a base-match: MB's title is a literal prefix
        // of the DJ's, so the tier defaults to .merge.
        let candidate = makeCandidate(
            proposedArtist: "Foo Artist",
            proposedTitle: "Foo Song Title",
            proposedAlbum: "Foo Album",
            proposedYear: 2000,
            currentFileYear: 1999,
            currentFileArtist: "Foo Artist (feat. Bar)",
            currentFileTitle: "Foo Song Title [DJ foobar remix - radio version]",
            currentFileAlbum: "Old Album"
        )
        var model = AutoTagRowModel(candidate: candidate)

        XCTAssertEqual(
            model.payload().title,
            "Foo Song Title [DJ foobar remix - radio version]"
        )

        model.includeAlbum = false
        XCTAssertNil(model.payload().album)

        model.titleChoice = .keep
        XCTAssertNil(model.payload().title, "E-K: .keep must omit the title, not write the current title back")

        // Identity is always present regardless of toggles.
        let payload = model.payload()
        XCTAssertEqual(payload.recordingMBID, candidate.recordingMBID)
        XCTAssertEqual(payload.acoustID, candidate.acoustID)
        XCTAssertEqual(payload.artistMBID, candidate.artistMBID)
        XCTAssertEqual(payload.isrc, candidate.isrc)
        XCTAssertEqual(payload.fingerprintHash, candidate.fingerprintHash)
    }

    // MARK: - E-K: .keep omits the title from the payload entirely

    /// `.keep` must encode as an OMITTED title update (`payload().title
    /// == nil`), not the current-title written back — otherwise
    /// `applyMusicBrainzMatch` overwrites the canonical `tracks.title`
    /// (and the user's `(Clean)/(Dirty)/(Radio Version)` flags) even
    /// though the user chose Keep.
    func testKeepTitleChoiceOmitsTitleFromPayload() {
        let candidate = makeCandidate(proposedTitle: "Corrected Title", currentFileTitle: "Original (Clean)")
        var model = AutoTagRowModel(candidate: candidate)
        model.titleChoice = .keep

        XCTAssertNil(model.payload().title)
        XCTAssertEqual(model.resolvedTitle, "Original (Clean)", "the review row still shows the current title live")
    }

    func testMergeTitleChoiceIncludesResolvedTitleInPayload() {
        // Base-match: MB's title is a literal prefix of the DJ's tagged one.
        let candidate = makeCandidate(
            proposedTitle: "Foo Song Title",
            currentFileTitle: "Foo Song Title [DJ foobar remix - radio version]"
        )
        var model = AutoTagRowModel(candidate: candidate)
        model.titleChoice = .merge

        XCTAssertEqual(model.payload().title, model.resolvedTitle)
        XCTAssertNotNil(model.payload().title)
    }

    func testTitleChoiceTakeUsesProposedTitleVerbatim() {
        let candidate = makeCandidate(proposedTitle: "Corrected Title", currentFileTitle: "Totally Different Title")
        var model = AutoTagRowModel(candidate: candidate)
        model.titleChoice = .take
        XCTAssertEqual(model.payload().title, "Corrected Title")
    }

    // MARK: - Default include flags follow "differs from current"

    func testFieldsDefaultIncludedOnlyWhenTheyDifferFromCurrent() {
        let candidate = makeCandidate(
            proposedArtist: "Same Artist",
            proposedAlbum: "Same Album",
            proposedYear: 1994,
            currentFileYear: 1994,
            currentFileArtist: "Same Artist",
            currentFileTitle: "Some Title",
            currentFileAlbum: "Same Album"
        )
        let model = AutoTagRowModel(candidate: candidate)

        XCTAssertFalse(model.includeArtist, "artist matches current — should default off")
        XCTAssertFalse(model.includeAlbum, "album matches current — should default off")
        XCTAssertFalse(model.includeYear, "year matches current — should default off")

        let payload = model.payload()
        XCTAssertNil(payload.artist)
        XCTAssertNil(payload.album)
        XCTAssertNil(payload.year)
    }

    func testFieldsDefaultIncludedWhenTheyDifferFromCurrent() {
        let candidate = makeCandidate(
            proposedArtist: "New Artist",
            proposedAlbum: "New Album",
            proposedYear: 2001,
            currentFileYear: 1994,
            currentFileArtist: "Old Artist",
            currentFileTitle: "Some Title",
            currentFileAlbum: "Old Album"
        )
        let model = AutoTagRowModel(candidate: candidate)

        XCTAssertTrue(model.includeArtist)
        XCTAssertTrue(model.includeAlbum)
        XCTAssertTrue(model.includeYear)

        let payload = model.payload()
        XCTAssertEqual(payload.artist, "New Artist")
        XCTAssertEqual(payload.album, "New Album")
        XCTAssertEqual(payload.year, 2001)
    }

    // MARK: - Toggling artist off omits it independent of title/album

    func testTogglingArtistOffOmitsItButLeavesOtherFieldsIntact() {
        let candidate = makeCandidate(
            proposedArtist: "New Artist",
            proposedAlbum: "New Album",
            currentFileArtist: "Old Artist",
            currentFileTitle: "Some Title",
            currentFileAlbum: "Old Album"
        )
        var model = AutoTagRowModel(candidate: candidate)
        model.includeArtist = false

        let payload = model.payload()
        XCTAssertNil(payload.artist)
        XCTAssertEqual(payload.album, "New Album")
    }

    // MARK: - Release selection updates the payload's album + release id

    func testSelectingADifferentReleaseUpdatesAlbumAndReleaseMBID() {
        let originalRelease = makeRelease(id: "release-a", title: "Album A")
        let otherRelease = makeRelease(id: "release-b", title: "Album B")
        let candidate = makeCandidate(
            proposedAlbum: "Album A",
            chosenRelease: originalRelease,
            availableReleases: [originalRelease, otherRelease],
            currentFileAlbum: "Old Album"
        )
        var model = AutoTagRowModel(candidate: candidate)

        model.selectRelease(otherRelease)

        XCTAssertEqual(model.payload().album, "Album B")
        XCTAssertEqual(model.payload().releaseMBID, "release-b")
    }

    // MARK: - B3: selecting a release recomputes the automatic album default

    /// The default release's title equals `currentAlbum`, so `includeAlbum`
    /// starts `false` (nothing to change). Picking a *different* release
    /// whose title differs from `currentAlbum` must flip `includeAlbum` on
    /// — otherwise `payload().album` stays `nil` despite the user
    /// explicitly choosing that release.
    func testSelectingDifferentReleaseRecomputesIncludeAlbumWhenNotOverridden() {
        let currentAlbum = "Current Album"
        let defaultRelease = makeRelease(id: "release-a", title: currentAlbum)
        let otherRelease = makeRelease(id: "release-b", title: "A Different Album")
        let candidate = makeCandidate(
            proposedAlbum: currentAlbum,
            chosenRelease: defaultRelease,
            availableReleases: [defaultRelease, otherRelease],
            currentFileAlbum: currentAlbum
        )
        var model = AutoTagRowModel(candidate: candidate)
        XCTAssertFalse(model.includeAlbum, "default release's title matches current album — starts off")

        model.selectRelease(otherRelease)

        XCTAssertTrue(model.includeAlbum, "a different release's title should turn the automatic default on")
        XCTAssertEqual(model.payload().album, "A Different Album")
    }

    /// Once the user has manually flipped the album toggle, a later
    /// `selectRelease` (browsing releases in the disclosure) must leave
    /// their choice alone rather than recomputing the automatic default.
    func testSelectingDifferentReleaseLeavesUserOverriddenToggleAlone() {
        let currentAlbum = "Current Album"
        let defaultRelease = makeRelease(id: "release-a", title: currentAlbum)
        let otherRelease = makeRelease(id: "release-b", title: "A Different Album")
        let candidate = makeCandidate(
            proposedAlbum: currentAlbum,
            chosenRelease: defaultRelease,
            availableReleases: [defaultRelease, otherRelease],
            currentFileAlbum: currentAlbum
        )
        var model = AutoTagRowModel(candidate: candidate)

        // Simulate the user manually turning the toggle off (as the view's
        // binding does via markAlbumToggleUserOverridden()).
        model.includeAlbum = false
        model.markAlbumToggleUserOverridden()

        model.selectRelease(otherRelease)

        XCTAssertFalse(model.includeAlbum, "a user override must survive selecting a different release")
        XCTAssertNil(model.payload().album)
    }

    // MARK: - E-A: unavailable (nil) proposed artist is never applied as blank

    /// A sparse MusicBrainz recording with an empty artist-credit yields
    /// `proposedArtist == nil` — must never default to "included" (which
    /// would blank the file's real artist on Confirm-All) and must never
    /// be applied as an empty string.
    func testNilProposedArtistNeverDefaultsIncludedOrAppliesBlank() {
        let candidate = makeCandidate(
            proposedArtist: nil,
            currentFileArtist: "Existing Real Artist",
            currentFileTitle: "Some Title",
            currentFileAlbum: "Album"
        )
        let model = AutoTagRowModel(candidate: candidate)

        XCTAssertFalse(model.includeArtist, "an unavailable proposed artist must never default to included")
        XCTAssertNil(model.payload().artist, "Confirm-All must never blank the existing artist")
    }

    /// Even if a caller force-toggles `includeArtist` on for a nil
    /// proposal, `payload()` must not fabricate an empty-string artist —
    /// there's nothing to apply.
    func testForcingIncludeArtistOnWithNilProposalNeverAppliesBlank() {
        let candidate = makeCandidate(
            proposedArtist: nil,
            currentFileArtist: "Existing Real Artist",
            currentFileTitle: "Some Title",
            currentFileAlbum: "Album"
        )
        var model = AutoTagRowModel(candidate: candidate)
        model.includeArtist = true

        XCTAssertNil(model.payload().artist, "toggling on a nil proposed artist must not fabricate one")
    }

    // MARK: - No proposed year

    func testNoProposedYearNeverIncludesYear() {
        let candidate = makeCandidate(proposedYear: nil, currentFileYear: 1990)
        var model = AutoTagRowModel(candidate: candidate)
        XCTAssertFalse(model.includeYear)
        model.includeYear = true
        XCTAssertNil(model.payload().year, "toggling on a nil proposed year must not fabricate one")
    }

    // MARK: - On-disk embedded tags are the review baseline (not the DB snapshot)

    /// The file's embedded artist/title/album (`candidate.currentFile*`) is
    /// the baseline for the include-toggle defaults and the diff — not any
    /// Serato/DB `files` snapshot. When the audio file's tag is wrong, the
    /// toggles must default ON so Apply fixes the file.
    func testOnDiskEmbeddedTagsAreTheBaseline() {
        // The file on disk is wrong ("Unknown Artist" / blank album), and
        // MusicBrainz proposes the correct values. The diff must be
        // file→proposed, and the toggles must default ON so Apply fixes it.
        let candidate = makeCandidate(
            proposedArtist: "Nas",
            proposedTitle: "N.Y. State of Mind",
            proposedAlbum: "Illmatic",
            proposedYear: 1994,
            currentFileArtist: "Unknown Artist",
            currentFileTitle: "Track 03",
            currentFileAlbum: ""
        )
        let model = AutoTagRowModel(candidate: candidate)

        XCTAssertEqual(model.currentArtist, "Unknown Artist", "baseline is the file's embedded tag")
        XCTAssertEqual(model.currentTitle, "Track 03")
        XCTAssertEqual(model.currentAlbum, "")
        XCTAssertTrue(model.includeArtist, "file tag differs from proposed — Apply must fix it")
        XCTAssertTrue(model.includeAlbum, "blank file album differs from proposed — Apply must fix it")

        let payload = model.payload()
        XCTAssertEqual(payload.artist, "Nas")
        XCTAssertEqual(payload.album, "Illmatic")
    }

    // MARK: - #3999974015: a definitively-absent embedded tag stays absent

    /// When the file has NO embedded artist/album tag (`currentFile* == nil`),
    /// the baseline is treated as absent (""), NOT backfilled from any DB
    /// snapshot. So even if the proposal equals what Serato already stored,
    /// the include-toggle defaults ON — Confirm-All must WRITE the missing tag
    /// to the file, and the diff must show the honest "«» → proposed".
    func testMissingEmbeddedTagDefaultsIncludeOnSoTheFileGetsWritten() {
        let candidate = makeCandidate(
            proposedArtist: "Nas",
            proposedAlbum: "Illmatic",
            currentFileArtist: nil,
            currentFileAlbum: nil
        )
        let model = AutoTagRowModel(candidate: candidate)

        XCTAssertEqual(model.currentArtist, "", "a missing file tag reads as absent, not the DB value")
        XCTAssertEqual(model.currentAlbum, "")
        XCTAssertTrue(model.includeArtist, "a missing file tag must default ON so Apply writes it")
        XCTAssertTrue(model.includeAlbum)

        let payload = model.payload()
        XCTAssertEqual(payload.artist, "Nas")
        XCTAssertEqual(payload.album, "Illmatic")
    }

    // MARK: - On-disk current year

    /// The file's on-disk year already matches proposed → `includeYear` off,
    /// nothing to change.
    func testOnDiskCurrentYearEqualToProposedDefaultsIncludeYearOff() {
        let candidate = makeCandidate(proposedYear: 1994, currentFileYear: 1994)
        let model = AutoTagRowModel(candidate: candidate)

        XCTAssertFalse(model.includeYear, "on-disk year already matches proposed — nothing to change")
        XCTAssertEqual(model.currentYear, 1994)
        XCTAssertNil(model.payload().year)
    }

    /// The on-disk tag disagrees with the proposed year: `includeYear` must
    /// default ON so the honest diff ("1990 → 1994") is what applies.
    func testOnDiskCurrentYearDifferingFromProposedDefaultsIncludeYearOn() {
        let candidate = makeCandidate(proposedYear: 1994, currentFileYear: 1990)
        let model = AutoTagRowModel(candidate: candidate)

        XCTAssertTrue(model.includeYear, "on-disk year differs from proposed — should default on")
        XCTAssertEqual(model.currentYear, 1990)
        XCTAssertEqual(model.payload().year, 1994)
    }

    /// #3999974015 (year): a file with NO year tag but a proposed year must
    /// default `includeYear` ON — the file's missing year is written, not
    /// left absent because some canonical `tracks.year` happened to match.
    func testMissingOnDiskYearWithProposedYearDefaultsIncludeYearOn() {
        let candidate = makeCandidate(proposedYear: 1994, currentFileYear: nil)
        let model = AutoTagRowModel(candidate: candidate)

        XCTAssertTrue(model.includeYear, "a missing file year with a proposed year must default on")
        XCTAssertNil(model.currentYear, "the baseline reflects the file's absent year, not a DB value")
        XCTAssertEqual(model.payload().year, 1994)
    }
}
