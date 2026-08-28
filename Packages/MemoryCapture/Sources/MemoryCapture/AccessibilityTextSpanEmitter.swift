import Foundation
import MemoryContracts

public struct AccessibilityTextSpanEmitter: Sendable {
    public init() {}

    public func emit(
        snapshot: AccessibilitySnapshot,
        frameID: UUID,
        idProvider: (Int) -> UUID = { _ in UUID() }
    ) throws -> [TextSpan] {
        guard snapshot.status == .useful else {
            return []
        }
        return try emit(
            elements: snapshot.elements,
            windowBounds: snapshot.target.bounds,
            frameID: frameID,
            idProvider: idProvider
        )
    }

    public func emit<Elements: Sequence>(
        elements: Elements,
        windowBounds: PointRect,
        frameID: UUID,
        idProvider: (Int) -> UUID = { _ in UUID() }
    ) throws -> [TextSpan] where Elements.Element == ProjectedAccessibilityElement {
        let orderedElements = elements.sorted(by: Self.elementOrder)
        var accepted: [Candidate] = []

        for element in orderedElements {
            let secure =
                element.role == "AXSecureTextField"
                || element.subrole == "AXSecureTextField"
            let projectedBounds = normalized(element.bounds, within: windowBounds)
            let rawValues = [
                element.title,
                secure ? nil : element.value,
                element.nodeDescription,
                element.help,
            ]

            for rawValue in rawValues {
                guard let rawValue else {
                    continue
                }
                let text = TextSpan.normalize(rawValue)
                guard !text.isEmpty else {
                    continue
                }
                let candidate = Candidate(text: text, bounds: projectedBounds)
                guard !accepted.contains(where: { Self.isDuplicate(candidate, of: $0) }) else {
                    continue
                }
                accepted.append(candidate)
            }
        }

        return try accepted.enumerated().map { index, candidate in
            try TextSpan(
                id: idProvider(index),
                frameID: frameID,
                source: .accessibility,
                text: candidate.text,
                bounds: candidate.bounds,
                confidence: nil,
                languageCode: nil,
                sensitivity: .normal
            )
        }
    }

    private func normalized(_ bounds: PointRect?, within window: PointRect) -> NormalizedRect? {
        guard let bounds,
            [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite),
            [window.x, window.y, window.width, window.height].allSatisfy(\.isFinite),
            bounds.width > 0, bounds.height > 0, window.width > 0, window.height > 0
        else {
            return nil
        }
        let left = max(window.x, bounds.x)
        let top = max(window.y, bounds.y)
        let right = min(window.x + window.width, bounds.x + bounds.width)
        let bottom = min(window.y + window.height, bounds.y + bounds.height)
        guard right > left, bottom > top else {
            return nil
        }

        let x = min(1, max(0, (left - window.x) / window.width))
        let y = min(1, max(0, (top - window.y) / window.height))
        let width = min(1 - x, (right - left) / window.width)
        let height = min(1 - y, (bottom - top) / window.height)
        return try? NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private static func elementOrder(
        _ left: ProjectedAccessibilityElement,
        _ right: ProjectedAccessibilityElement
    ) -> Bool {
        if left.hierarchyPath != right.hierarchyPath {
            return left.hierarchyPath.lexicographicallyPrecedes(right.hierarchyPath)
        }
        if left.signature != right.signature {
            return left.signature < right.signature
        }
        return left.role < right.role
    }

    private static func isDuplicate(_ candidate: Candidate, of existing: Candidate) -> Bool {
        guard candidate.text == existing.text else {
            return false
        }
        switch (candidate.bounds, existing.bounds) {
        case (let left?, let right?):
            return intersectionOverUnion(left, right) >= 0.5
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private static func intersectionOverUnion(_ left: NormalizedRect, _ right: NormalizedRect)
        -> Double
    {
        let intersectionLeft = max(left.x, right.x)
        let intersectionTop = max(left.y, right.y)
        let intersectionRight = min(left.x + left.width, right.x + right.width)
        let intersectionBottom = min(left.y + left.height, right.y + right.height)
        let intersectionWidth = max(0, intersectionRight - intersectionLeft)
        let intersectionHeight = max(0, intersectionBottom - intersectionTop)
        let intersection = intersectionWidth * intersectionHeight
        let union = left.width * left.height + right.width * right.height - intersection
        return union > 0 ? intersection / union : 0
    }
}

private struct Candidate {
    let text: String
    let bounds: NormalizedRect?
}
