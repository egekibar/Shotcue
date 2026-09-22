import Testing

@testable import ShotcueCore

@Suite("SortIndex")
struct SortIndexTests {
    @Test func appendsAfterLast() { #expect(SortIndex.between(3072, nil) == 3072 + SortIndex.step) }
    @Test func prependsBeforeFirst() { #expect(SortIndex.between(nil, 1024) == 0) }
    @Test func emptyListStartsAtStep() { #expect(SortIndex.between(nil, nil) == SortIndex.step) }
    @Test func midpointBetweenNeighbors() { #expect(SortIndex.between(1024, 2048) == 1536) }
    @Test func detectsExhaustedGap() {
        #expect(SortIndex.needsRenumber(1.0, 1.0 + 1e-9) == true)
        #expect(SortIndex.needsRenumber(1024, 2048) == false)
    }
    @Test func renumberProducesEvenSteps() { #expect(SortIndex.renumbered(count: 3) == [1024, 2048, 3072]) }
}
