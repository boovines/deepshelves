import Foundation

public struct S6Card: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let applicationName: String
    public let minuteOfDay: Int
    public let mediaFrameIndex: Int

    public init(
        id: Int,
        title: String,
        applicationName: String,
        minuteOfDay: Int,
        mediaFrameIndex: Int
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.minuteOfDay = minuteOfDay
        self.mediaFrameIndex = mediaFrameIndex
    }
}

public struct S6TimelineMarker: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let minuteOfDay: Int
    public let isGap: Bool

    public init(id: Int, minuteOfDay: Int, isGap: Bool) {
        self.id = id
        self.minuteOfDay = minuteOfDay
        self.isGap = isGap
    }
}

public struct S6Fixture: Codable, Equatable, Sendable {
    public let cards: [S6Card]
    public let timeline: [S6TimelineMarker]

    public init(cards: [S6Card], timeline: [S6TimelineMarker]) {
        self.cards = cards
        self.timeline = timeline
    }

    public static func make(
        cardCount: Int = LM008UIDefaults.fixtureCardCount,
        timelineHours: Int = LM008UIDefaults.timelineHours
    ) -> S6Fixture {
        let applications = ["Mail", "Safari", "Xcode", "Notes", "Calendar"]
        let cards = (0 ..< cardCount).map { index in
            S6Card(
                id: index,
                title: "Local memory result \(index + 1)",
                applicationName: applications[index % applications.count],
                minuteOfDay: index % max(1, timelineHours * 60),
                mediaFrameIndex: index % 96
            )
        }
        let markerCount = max(1, timelineHours * 4)
        let timeline = (0 ..< markerCount).map { index in
            S6TimelineMarker(
                id: index,
                minuteOfDay: index * 15,
                isGap: index % 17 == 8 || index % 29 == 14
            )
        }
        return S6Fixture(cards: cards, timeline: timeline)
    }
}

public actor S6LRUCache<Key: Hashable & Sendable, Value: Sendable> {
    private let capacity: Int
    private var storage: [Key: Value] = [:]
    private var recency: [Key] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int {
        storage.count
    }

    public func value(for key: Key) -> Value? {
        guard let value = storage[key] else {
            return nil
        }
        markRecent(key)
        return value
    }

    public func insert(_ value: Value, for key: Key) {
        storage[key] = value
        markRecent(key)
        while storage.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    public func removeAll() {
        storage.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
    }

    private func markRecent(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

public struct S6SelectionToken: Codable, Equatable, Sendable {
    public let cardID: Int
    public let generation: Int

    public init(cardID: Int, generation: Int) {
        self.cardID = cardID
        self.generation = generation
    }
}

public actor S6SelectionCoordinator {
    private var generation = 0

    public init() {}

    public func beginSelection(cardID: Int) -> S6SelectionToken {
        generation += 1
        return S6SelectionToken(cardID: cardID, generation: generation)
    }

    public func canPublish(_ token: S6SelectionToken) -> Bool {
        token.generation == generation
    }
}

public enum S6Metrics: Sendable {
    public static func percentile(_ samples: [Double], quantile: Double) -> Double {
        guard !samples.isEmpty else {
            return 0
        }
        let sorted = samples.sorted()
        let boundedQuantile = min(1, max(0, quantile))
        let index = max(0, Int(ceil(Double(sorted.count) * boundedQuantile)) - 1)
        return sorted[min(index, sorted.count - 1)]
    }
}
