@testable import CrateAgent
import XCTest

final class TitleMatcherTests: XCTestCase {
    // MARK: - exact

    func testExact() {
        XCTAssertEqual(TitleMatcher.decide(current: "foo song title", proposed: "Foo Song Title").defaultChoice, .take)
    }

    func testExactNormalizesInternalWhitespace() {
        let decision = TitleMatcher.decide(current: "Foo   Song  Title", proposed: "Foo Song Title")
        XCTAssertEqual(decision.tier, .exact)
        XCTAssertEqual(decision.defaultChoice, .take)
    }

    // MARK: - baseMatch

    func testBaseMatchMergesPreservingRemainder() {
        let decision = TitleMatcher.decide(
            current: "foo song title [DJ foobar remix - radio version]",
            proposed: "Foo Song Title"
        )
        XCTAssertEqual(decision.tier, .baseMatch(merged: "Foo Song Title [DJ foobar remix - radio version]"))
        XCTAssertEqual(decision.defaultChoice, .merge)
    }

    func testCuratorCreditKeptViaMerge() {
        let decision = TitleMatcher.decide(current: "Foo Song (MM Edit)", proposed: "Foo Song")
        XCTAssertEqual(decision.tier, .baseMatch(merged: "Foo Song (MM Edit)"))
        XCTAssertEqual(decision.defaultChoice, .merge)
    }

    func testBracketRemainderMerges() {
        let decision = TitleMatcher.decide(current: "foo [clean]", proposed: "Foo")
        XCTAssertEqual(
            TitleMatcher.value(for: .merge, current: "foo [clean]", proposed: "Foo", tier: decision.tier),
            "Foo [clean]"
        )
    }

    func testDashRemainderMerges() {
        let decision = TitleMatcher.decide(current: "foo - radio edit", proposed: "Foo")
        XCTAssertEqual(
            TitleMatcher.value(for: .merge, current: "foo - radio edit", proposed: "Foo", tier: decision.tier),
            "Foo - radio edit"
        )
    }

    func testBareVocabPrefixMerges() {
        // "foo song radio edit" has no bracket/paren/dash delimiter, but its
        // normalized form is still a strict prefix extension of "Foo Song",
        // so it resolves via baseMatch rather than needing the bare-token
        // fallback at all.
        XCTAssertEqual(TitleMatcher.decide(current: "foo song radio edit", proposed: "Foo Song").defaultChoice, .merge)
    }

    // MARK: - annotationNoBase

    func testParenDirtyKeptWhenMBAlsoChangesBase() {
        let decision = TitleMatcher.decide(current: "Foo Sng (Dirty)", proposed: "Foo Song")
        XCTAssertEqual(decision.tier, .annotationNoBase)
        XCTAssertEqual(decision.defaultChoice, .keep)
    }

    func testBareVocabTokenWithoutDelimiterAndDifferentBaseIsKept() {
        // No parens/brackets/dash, AND the base itself differs (typo fix),
        // so this can only be caught by the bare-token vocabulary fallback.
        let decision = TitleMatcher.decide(current: "Foo Sog Dirty", proposed: "Foo Song")
        XCTAssertEqual(decision.tier, .annotationNoBase)
        XCTAssertEqual(decision.defaultChoice, .keep)
    }

    // MARK: - plain

    func testPlainCorrection() {
        XCTAssertEqual(TitleMatcher.decide(current: "Foo Sog", proposed: "Foo Song").defaultChoice, .take)
    }

    // MARK: - annotationSegments

    func testAnnotationSegmentsExtractsParenBracketAndTrailingDash() {
        XCTAssertEqual(TitleMatcher.annotationSegments(in: "Foo Song (Dirty)"), ["Dirty"])
        XCTAssertEqual(TitleMatcher.annotationSegments(in: "Foo Song [Clean]"), ["Clean"])
        XCTAssertEqual(TitleMatcher.annotationSegments(in: "Foo Song - Radio Edit"), ["Radio Edit"])
    }

    func testAnnotationSegmentsDoesNotDoubleCountADashNestedInsideABracket() {
        // The trailing content is inside "[...]"; the dash within it must not
        // also be reported as a separate trailing-dash segment.
        let segments = TitleMatcher.annotationSegments(in: "foo song title [DJ foobar remix - radio version]")
        XCTAssertEqual(segments, ["DJ foobar remix - radio version"])
    }

    // MARK: - hasDroppedAnnotation

    func testHasDroppedAnnotationTrueWhenSegmentContentMissingFromProposed() {
        XCTAssertTrue(TitleMatcher.hasDroppedAnnotation(current: "Foo Song (Dirty)", proposed: "Foo Song"))
    }

    func testHasDroppedAnnotationFalseWhenProposedRetainsSegmentContent() {
        XCTAssertFalse(
            TitleMatcher.hasDroppedAnnotation(current: "Foo Song (Dirty)", proposed: "Foo Song (Dirty) Extended")
        )
    }

    func testHasDroppedAnnotationFalseWhenNoAnnotationOrVocabPresent() {
        XCTAssertFalse(TitleMatcher.hasDroppedAnnotation(current: "Foo Song", proposed: "Foo Song Deluxe"))
    }

    // MARK: - value(for:current:proposed:tier:)

    func testValueKeepReturnsCurrent() {
        XCTAssertEqual(
            TitleMatcher.value(for: .keep, current: "Foo Sng (Dirty)", proposed: "Foo Song", tier: .annotationNoBase),
            "Foo Sng (Dirty)"
        )
    }

    func testValueTakeReturnsProposed() {
        XCTAssertEqual(
            TitleMatcher.value(for: .take, current: "Foo Sog", proposed: "Foo Song", tier: .plain),
            "Foo Song"
        )
    }

    func testValueMergeFallsBackToProposedWhenTierIsNotBaseMatch() {
        // `.merge` only has a well-defined payload when the tier is
        // `.baseMatch`. Forcing it against another tier (a caller error, but
        // one we must not crash on) falls back to the proposed title, same
        // as `.take`, since there is no located base+remainder split to use.
        XCTAssertEqual(
            TitleMatcher.value(for: .merge, current: "Foo Sog", proposed: "Foo Song", tier: .plain),
            "Foo Song"
        )
    }
}
