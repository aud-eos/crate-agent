@testable import CrateAgent
import XCTest

/// Unit tests for `AutoTagRowModel` — the plain, no-SwiftUI view-model
/// behind the Auto-Tag review row. Exercises payload assembly only;
/// the SwiftUI layer (`AutoTagReviewRow`, `AutoTaggerView`) is verified
/// by build, not by these tests.
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
        proposedArtist: String = "Test Artist",
        proposedTitle: String = "Test Title",
        proposedAlbum: String = "Test Album",
        proposedYear: Int? = 1994,
        chosenRelease: MBRelease? = nil,
        availableReleases: [MBRelease]? = nil,
        currentFileYear: Int? = nil
    ) -> MatchCandidate {
        let release = chosenRelease ?? makeRelease()
        return MatchCandidate(
            fileID: 1,
            score: 0.95,
            acoustID: "acoustid-1",
            recordingMBID: "recording-1",
            artistMBID: "artist-1",
            fingerprintHash: Data([0xAB, 0xCD, 0xEF]),
            chosenRelease: release,
            availableReleases: availableReleases ?? [release],
            isrc: "ISRC0000001",
            proposedArtist: proposedArtist,
            proposedTitle: proposedTitle,
            proposedAlbum: proposedAlbum,
            proposedYear: proposedYear,
            currentFileYear: currentFileYear
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
            proposedYear: 2000
        )
        var model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Foo Artist (feat. Bar)",
            currentTitle: "Foo Song Title [DJ foobar remix - radio version]",
            currentAlbum: "Old Album",
            currentYear: 1999
        )

        XCTAssertEqual(
            model.payload().title,
            "Foo Song Title [DJ foobar remix - radio version]"
        )

        model.includeAlbum = false
        XCTAssertNil(model.payload().album)

        model.titleChoice = .keep
        XCTAssertEqual(model.payload().title, model.currentTitle)

        // Identity is always present regardless of toggles.
        let payload = model.payload()
        XCTAssertEqual(payload.recordingMBID, candidate.recordingMBID)
        XCTAssertEqual(payload.acoustID, candidate.acoustID)
        XCTAssertEqual(payload.artistMBID, candidate.artistMBID)
        XCTAssertEqual(payload.isrc, candidate.isrc)
        XCTAssertEqual(payload.fingerprintHash, candidate.fingerprintHash)
    }

    func testTitleChoiceTakeUsesProposedTitleVerbatim() {
        let candidate = makeCandidate(proposedTitle: "Corrected Title")
        var model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Artist",
            currentTitle: "Totally Different Title",
            currentAlbum: "Album",
            currentYear: 1994
        )
        model.titleChoice = .take
        XCTAssertEqual(model.payload().title, "Corrected Title")
    }

    // MARK: - Default include flags follow "differs from current"

    func testFieldsDefaultIncludedOnlyWhenTheyDifferFromCurrent() {
        let candidate = makeCandidate(
            proposedArtist: "Same Artist",
            proposedAlbum: "Same Album",
            proposedYear: 1994
        )
        let model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Same Artist",
            currentTitle: "Some Title",
            currentAlbum: "Same Album",
            currentYear: 1994
        )

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
            proposedYear: 2001
        )
        let model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Old Artist",
            currentTitle: "Some Title",
            currentAlbum: "Old Album",
            currentYear: 1994
        )

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
        let candidate = makeCandidate(proposedArtist: "New Artist", proposedAlbum: "New Album")
        var model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Old Artist",
            currentTitle: "Some Title",
            currentAlbum: "Old Album",
            currentYear: nil
        )
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
            availableReleases: [originalRelease, otherRelease]
        )
        var model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Artist",
            currentTitle: "Title",
            currentAlbum: "Old Album",
            currentYear: nil
        )

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
            availableReleases: [defaultRelease, otherRelease]
        )
        var model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Artist",
            currentTitle: "Title",
            currentAlbum: currentAlbum,
            currentYear: nil
        )
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
            availableReleases: [defaultRelease, otherRelease]
        )
        var model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Artist",
            currentTitle: "Title",
            currentAlbum: currentAlbum,
            currentYear: nil
        )

        // Simulate the user manually turning the toggle off (as the view's
        // binding does via markAlbumToggleUserOverridden()).
        model.includeAlbum = false
        model.markAlbumToggleUserOverridden()

        model.selectRelease(otherRelease)

        XCTAssertFalse(model.includeAlbum, "a user override must survive selecting a different release")
        XCTAssertNil(model.payload().album)
    }

    // MARK: - No proposed year

    func testNoProposedYearNeverIncludesYear() {
        let candidate = makeCandidate(proposedYear: nil)
        var model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Artist",
            currentTitle: "Title",
            currentAlbum: "Album",
            currentYear: 1990
        )
        XCTAssertFalse(model.includeYear)
        model.includeYear = true
        XCTAssertNil(model.payload().year, "toggling on a nil proposed year must not fabricate one")
    }

    // MARK: - On-disk current year (greenfield first-pass match)

    /// A greenfield first-pass match: no `tracks` row exists yet, so the
    /// caller-supplied `tracks.year` (here `currentYear: nil`) is nil, but
    /// the file's on-disk tag (`candidate.currentFileYear`) already carries
    /// the correct year. `includeYear` must default OFF — the tag is
    /// already correct, there's nothing to change.
    func testOnDiskCurrentYearEqualToProposedDefaultsIncludeYearOff() {
        let candidate = makeCandidate(proposedYear: 1994, currentFileYear: 1994)
        let model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Artist",
            currentTitle: "Title",
            currentAlbum: "Album",
            currentYear: nil
        )

        XCTAssertFalse(model.includeYear, "on-disk year already matches proposed — nothing to change")
        XCTAssertEqual(model.currentYear, 1994)
        XCTAssertNil(model.payload().year)
    }

    /// Same greenfield scenario, but the on-disk tag disagrees with the
    /// proposed year: `includeYear` must default ON so the honest diff
    /// ("1990 → 1994") is what the review row shows and applies.
    func testOnDiskCurrentYearDifferingFromProposedDefaultsIncludeYearOn() {
        let candidate = makeCandidate(proposedYear: 1994, currentFileYear: 1990)
        let model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Artist",
            currentTitle: "Title",
            currentAlbum: "Album",
            currentYear: nil
        )

        XCTAssertTrue(model.includeYear, "on-disk year differs from proposed — should default on")
        XCTAssertEqual(model.currentYear, 1990)
        XCTAssertEqual(model.payload().year, 1994)
    }

    /// When the on-disk read didn't produce a year (`currentFileYear` nil,
    /// e.g. the tag has no year frame), the caller-supplied `tracks.year`
    /// is still an honest fallback for the diff.
    func testFallsBackToTracksYearWhenOnDiskYearMissing() {
        let candidate = makeCandidate(proposedYear: 1994, currentFileYear: nil)
        let model = AutoTagRowModel(
            candidate: candidate,
            currentArtist: "Artist",
            currentTitle: "Title",
            currentAlbum: "Album",
            currentYear: 1994
        )

        XCTAssertFalse(model.includeYear, "tracks.year fallback matches proposed — nothing to change")
        XCTAssertEqual(model.currentYear, 1994)
    }
}
