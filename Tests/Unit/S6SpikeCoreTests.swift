import Foundation
import MemoryDesignSystem
import Testing

@Suite("LM-008 S6 native UI spike core")
struct S6SpikeCoreTests {
    @Test("The native fixture is deterministic, stable, and complete")
    func deterministicFixture() {
        let first = S6Fixture.make()
        let second = S6Fixture.make()

        #expect(first == second)
        #expect(first.cards.count == LM008UIDefaults.fixtureCardCount)
        #expect(Set(first.cards.map(\.id)).count == first.cards.count)
        #expect(first.timeline.count == 96)
        #expect(first.timeline.first?.minuteOfDay == 0)
        #expect(first.timeline.last?.minuteOfDay == 1_425)
        let includesGap = first.timeline.contains { marker in marker.isGap }
        #expect(includesGap)
    }

    @Test("The actor cache is bounded and refreshes recency")
    func boundedActorCache() async {
        let cache = S6LRUCache<Int, String>(capacity: 2)
        await cache.insert("one", for: 1)
        await cache.insert("two", for: 2)
        #expect(await cache.value(for: 1) == "one")
        await cache.insert("three", for: 3)

        #expect(await cache.value(for: 1) == "one")
        #expect(await cache.value(for: 2) == nil)
        #expect(await cache.value(for: 3) == "three")
        #expect(await cache.count == 2)
    }

    @Test("Only the newest rapid selection can publish")
    func staleSelectionSuppression() async {
        let coordinator = S6SelectionCoordinator()
        let first = await coordinator.beginSelection(cardID: 10)
        let second = await coordinator.beginSelection(cardID: 20)

        #expect(await coordinator.canPublish(first) == false)
        #expect(await coordinator.canPublish(second))
        #expect(second.cardID == 20)
        #expect(second.generation == first.generation + 1)
    }

    @Test("S6 percentile uses the nearest-rank definition")
    func nearestRankPercentile() {
        #expect(S6Metrics.percentile(Array(1 ... 100).map(Double.init), quantile: 0.95) == 95)
        #expect(S6Metrics.percentile([9, 1, 4], quantile: 0.95) == 9)
        #expect(S6Metrics.percentile([], quantile: 0.95) == 0)
    }
}
