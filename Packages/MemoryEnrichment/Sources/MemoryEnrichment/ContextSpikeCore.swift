import Foundation

public struct ContextRect: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func intersectionOverUnion(with other: ContextRect) -> Double {
        let left = max(x, other.x)
        let bottom = max(y, other.y)
        let right = min(x + width, other.x + other.width)
        let top = min(y + height, other.y + other.height)
        let intersection = max(0, right - left) * max(0, top - bottom)
        let union = (width * height) + (other.width * other.height) - intersection
        return union > 0 ? intersection / union : 0
    }
}

public struct AXFixtureNode: Codable, Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let description: String?
    public let help: String?
    public let identifier: String?
    public let frame: ContextRect?
    public let isEnabled: Bool?
    public let isFocused: Bool?
    public let children: [AXFixtureNode]

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        help: String? = nil,
        identifier: String? = nil,
        frame: ContextRect? = nil,
        isEnabled: Bool? = nil,
        isFocused: Bool? = nil,
        children: [AXFixtureNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.help = help
        self.identifier = identifier
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.children = children
    }
}

public struct AXTraversalLimits: Codable, Equatable, Sendable {
    public let maximumNodes: Int
    public let maximumDepth: Int
    public let maximumStringLength: Int

    public init(maximumNodes: Int = 512, maximumDepth: Int = 16, maximumStringLength: Int = 512) {
        self.maximumNodes = max(1, maximumNodes)
        self.maximumDepth = max(0, maximumDepth)
        self.maximumStringLength = max(1, maximumStringLength)
    }
}

public struct AXProjectedSpan: Codable, Equatable, Sendable {
    public let text: String
    public let role: String
    public let frame: ContextRect?
}

public struct AXProjection: Codable, Equatable, Sendable {
    public let spans: [AXProjectedSpan]
    public let nodesVisited: Int
    public let wasTruncated: Bool

    public var isUseful: Bool {
        !spans.isEmpty
    }
}

public struct BoundedAXProjector: Sendable {
    public let limits: AXTraversalLimits

    public init(limits: AXTraversalLimits = AXTraversalLimits()) {
        self.limits = limits
    }

    public func project(_ root: AXFixtureNode) -> AXProjection {
        var stack: [(node: AXFixtureNode, depth: Int)] = [(root, 0)]
        var spans: [AXProjectedSpan] = []
        var seen: Set<String> = []
        var nodesVisited = 0
        var wasTruncated = false

        while let item = stack.popLast() {
            guard nodesVisited < limits.maximumNodes else {
                wasTruncated = true
                break
            }
            nodesVisited += 1

            let isSecure = item.node.role == "AXSecureTextField"
                || item.node.subrole == "AXSecureTextField"
            let candidates: [String?] = [
                item.node.title,
                isSecure ? nil : item.node.value,
                item.node.description,
                item.node.help,
            ]
            for candidate in candidates {
                guard let normalized = ContextTextNormalizer.normalize(candidate), !seen.contains(normalized) else {
                    continue
                }
                seen.insert(normalized)
                spans.append(
                    AXProjectedSpan(
                        text: String(normalized.prefix(limits.maximumStringLength)),
                        role: item.node.role,
                        frame: item.node.frame
                    )
                )
            }

            if item.depth < limits.maximumDepth {
                for child in item.node.children.reversed() {
                    stack.append((child, item.depth + 1))
                }
            } else if !item.node.children.isEmpty {
                wasTruncated = true
            }
        }

        if !stack.isEmpty {
            wasTruncated = true
        }
        return AXProjection(spans: spans, nodesVisited: nodesVisited, wasTruncated: wasTruncated)
    }
}

public enum ContextTextNormalizer {
    public static func normalize(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \ .isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    public static func comparisonKey(_ value: String) -> String {
        normalize(value)?.lowercased(with: Locale(identifier: "en_US_POSIX")) ?? ""
    }
}

public enum ContextTextSource: String, Codable, CaseIterable, Sendable {
    case accessibility
    case visionOCR
}

public struct ContextTextObservation: Codable, Equatable, Sendable {
    public let text: String
    public let normalizedText: String
    public let source: ContextTextSource
    public let bounds: ContextRect?
    public let confidence: Double?

    public init(
        text: String,
        source: ContextTextSource,
        bounds: ContextRect?,
        confidence: Double? = nil
    ) {
        self.text = ContextTextNormalizer.normalize(text) ?? ""
        normalizedText = ContextTextNormalizer.comparisonKey(text)
        self.source = source
        self.bounds = bounds
        self.confidence = confidence
    }
}

public struct AXOCRMerger: Sendable {
    public init() {}

    public func merge<Accessibility: Sequence, OCR: Sequence>(
        accessibility: Accessibility,
        ocr: OCR
    ) -> [ContextTextObservation]
    where Accessibility.Element == ContextTextObservation, OCR.Element == ContextTextObservation {
        let accessibilityValues = accessibility.filter { !$0.normalizedText.isEmpty }
        var merged = Array(accessibilityValues)
        let sortedOCR = ocr
            .filter { !$0.normalizedText.isEmpty }
            .sorted(by: Self.stableOrder)

        for observation in sortedOCR {
            let duplicate = accessibilityValues.contains { existing in
                guard existing.normalizedText == observation.normalizedText else {
                    return false
                }
                switch (existing.bounds, observation.bounds) {
                case let (left?, right?):
                    return left.intersectionOverUnion(with: right) >= 0.5
                case (nil, nil):
                    return true
                default:
                    return false
                }
            }
            if !duplicate {
                merged.append(observation)
            }
        }
        return merged.sorted(by: Self.stableOrder)
    }

    private static func stableOrder(_ left: ContextTextObservation, _ right: ContextTextObservation) -> Bool {
        let leftBounds = left.bounds ?? ContextRect(x: 2, y: 2, width: 0, height: 0)
        let rightBounds = right.bounds ?? ContextRect(x: 2, y: 2, width: 0, height: 0)
        let leftKey = (
            leftBounds.y,
            leftBounds.x,
            left.normalizedText,
            left.source == .accessibility ? 0 : 1
        )
        let rightKey = (
            rightBounds.y,
            rightBounds.x,
            right.normalizedText,
            right.source == .accessibility ? 0 : 1
        )
        if leftKey.0 != rightKey.0 { return leftKey.0 < rightKey.0 }
        if leftKey.1 != rightKey.1 { return leftKey.1 < rightKey.1 }
        if leftKey.2 != rightKey.2 { return leftKey.2 < rightKey.2 }
        return leftKey.3 < rightKey.3
    }
}

public enum BrowserFamily: String, Codable, CaseIterable, Sendable {
    case safari
    case chromium
    case firefox
}

public struct BrowserContextFixture: Codable, Equatable, Sendable {
    public let family: BrowserFamily
    public let bundleID: String
    public let resolvedWindowToken: String
    public var observationWindowToken: String
    public let isPrivateHint: Bool
    public let nodes: [AXFixtureNode]

    public init(
        family: BrowserFamily,
        bundleID: String,
        resolvedWindowToken: String,
        observationWindowToken: String,
        isPrivateHint: Bool,
        nodes: [AXFixtureNode]
    ) {
        self.family = family
        self.bundleID = bundleID
        self.resolvedWindowToken = resolvedWindowToken
        self.observationWindowToken = observationWindowToken
        self.isPrivateHint = isPrivateHint
        self.nodes = nodes
    }
}

public struct ApprovedBrowserContext: Codable, Equatable, Sendable {
    public let family: BrowserFamily
    public let scheme: String
    public let host: String
    public let path: String?
    public let serializedURL: String
}

public enum BrowserSuppressionReason: String, Codable, Equatable, Sendable {
    case privateContext
    case targetWindowMismatch
    case urlUnavailableWithSiteRule
    case unsupportedURL
}

public enum BrowserInspectionDecision: Codable, Equatable, Sendable {
    case approved(ApprovedBrowserContext)
    case metadataOnly
    case suppressed(BrowserSuppressionReason)
}

public struct BrowserContextAdapter: Sendable {
    public init() {}

    public func inspect(
        _ fixture: BrowserContextFixture,
        siteRulesExist: Bool
    ) -> BrowserInspectionDecision {
        guard fixture.resolvedWindowToken == fixture.observationWindowToken else {
            return .suppressed(.targetWindowMismatch)
        }
        guard !fixture.isPrivateHint else {
            return .suppressed(.privateContext)
        }
        guard let rawURL = urlCandidate(in: fixture) else {
            return siteRulesExist ? .suppressed(.urlUnavailableWithSiteRule) : .metadataOnly
        }
        guard let normalized = normalize(rawURL, family: fixture.family) else {
            return siteRulesExist ? .suppressed(.unsupportedURL) : .metadataOnly
        }
        return .approved(normalized)
    }

    private func urlCandidate(in fixture: BrowserContextFixture) -> String? {
        fixture.nodes.lazy.compactMap { node -> String? in
            let role = node.role.lowercased()
            let descriptor = [node.description, node.identifier, node.help]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            switch fixture.family {
            case .safari:
                if role == "axdocument" || descriptor.contains("address") || descriptor.contains("url") {
                    return node.value
                }
            case .chromium:
                if (role == "axtextfield" || role == "axcombobox")
                    && (descriptor.contains("address") || descriptor.contains("location"))
                {
                    return node.value
                }
            case .firefox:
                if (role == "axtextfield" || role == "axcombobox")
                    && (descriptor.contains("address") || descriptor.contains("search") || descriptor.contains("url"))
                {
                    return node.value
                }
            }
            return nil
        }.first
    }

    private func normalize(_ rawURL: String, family: BrowserFamily) -> ApprovedBrowserContext? {
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        let path = components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
            ? nil
            : components.percentEncodedPath
        components.percentEncodedPath = path ?? ""
        guard let serialized = components.string else {
            return nil
        }
        return ApprovedBrowserContext(
            family: family,
            scheme: scheme,
            host: host,
            path: path,
            serializedURL: serialized
        )
    }
}

public struct ContextArtifactBundle: Codable, Equatable, Sendable {
    public let media: String?
    public let thumbnail: String?
    public let text: String?
    public let title: String?
    public let url: String?
    public let vector: String?
    public let cache: String?
    public let log: String?

    public init(
        media: String? = nil,
        thumbnail: String? = nil,
        text: String? = nil,
        title: String? = nil,
        url: String? = nil,
        vector: String? = nil,
        cache: String? = nil,
        log: String? = nil
    ) {
        self.media = media
        self.thumbnail = thumbnail
        self.text = text
        self.title = title
        self.url = url
        self.vector = vector
        self.cache = cache
        self.log = log
    }

    public var isEmpty: Bool {
        media == nil && thumbnail == nil && text == nil && title == nil && url == nil
            && vector == nil && cache == nil && log == nil
    }

    public static let empty = ContextArtifactBundle()
}

public enum ContextPrivacyDecision: String, Codable, CaseIterable, Sendable {
    case allowed
    case excludedApplication
    case privateBrowser
    case deniedSite
    case unresolvedTarget
    case staleEpoch
    case protectedSurface
}

public struct ContextPrivacyGate: Sendable {
    public init() {}

    public func project(
        _ candidate: ContextArtifactBundle,
        decision: ContextPrivacyDecision,
        approvedWindowToken: String,
        observationWindowToken: String
    ) -> ContextArtifactBundle {
        guard decision == .allowed, approvedWindowToken == observationWindowToken else {
            return .empty
        }
        return candidate
    }
}

public struct S2AXFixture: Codable, Equatable, Sendable {
    public let id: String
    public let contextID: String
    public let root: AXFixtureNode
}

public struct S2OCRFixture: Codable, Equatable, Sendable {
    public let id: String
    public let words: [String]
    public let isHighContrastLatin: Bool
    public let foregroundLuma: Double
    public let backgroundLuma: Double
}

public struct S2PrivacyFixture: Codable, Equatable, Sendable {
    public let id: String
    public let decision: ContextPrivacyDecision
    public let sentinel: String
}

public struct S2FixtureCatalog: Codable, Equatable, Sendable {
    public let generatorVersion: String
    public let seed: UInt64
    public let axFixtures: [S2AXFixture]
    public let ocrFixtures: [S2OCRFixture]
    public let privacyFixtures: [S2PrivacyFixture]
    public let browserFixtures: [BrowserContextFixture]

    public static func make(seed: UInt64) -> S2FixtureCatalog {
        let contexts = [
            "safari", "chrome", "arc-dia", "edge", "firefox", "finder", "notes", "mail",
            "calendar", "preview-pdf", "terminal", "vscode", "xcode", "slack", "electron",
        ]
        let offset = Int(seed % UInt64(contexts.count))
        let axFixtures = (0 ..< 250).map { index in
            let context = contexts[(index + offset) % contexts.count]
            let title = "S2 \(context) fixture \(String(format: "%03d", index))"
            return S2AXFixture(
                id: "ax-\(String(format: "%03d", index))",
                contextID: context,
                root: AXFixtureNode(
                    role: "AXWindow",
                    title: title,
                    children: [
                        AXFixtureNode(
                            role: "AXStaticText",
                            title: "Approved visible \(context) context",
                            frame: ContextRect(x: 0.1, y: 0.1, width: 0.7, height: 0.1)
                        ),
                    ]
                )
            )
        }

        let vocabulary = [
            "archive", "calendar", "canvas", "chapter", "design", "document", "finder", "focus",
            "history", "inbox", "memory", "notes", "project", "review", "search", "terminal",
        ]
        let ocrFixtures = (0 ..< 200).map { index in
            let words = (0 ..< 4).map { wordIndex in
                vocabulary[(index * 3 + wordIndex + offset) % vocabulary.count]
            }
            let highContrast = index < 150
            return S2OCRFixture(
                id: "ocr-\(String(format: "%03d", index))",
                words: words,
                isHighContrastLatin: highContrast,
                foregroundLuma: highContrast ? 0.05 : 0.28,
                backgroundLuma: highContrast ? 0.98 : 0.72
            )
        }

        let denied = ContextPrivacyDecision.allCases.filter { $0 != .allowed }
        let privacyFixtures = (0 ..< 190).map { index in
            S2PrivacyFixture(
                id: "privacy-\(String(format: "%03d", index))",
                decision: denied[(index + offset) % denied.count],
                sentinel: "S2_FORBIDDEN_\(String(format: "%03d", index))"
            )
        }

        let browserFixtures = (0 ..< 500).map { index in
            let families = BrowserFamily.allCases
            let family = families[(index + offset) % families.count]
            let host = "fixture-\(index).example.test"
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/approved"
            components.queryItems = [URLQueryItem(name: "discard", value: "yes")]
            let fixtureAddress = components.string ?? ""
            let node: AXFixtureNode
            switch family {
            case .safari:
                node = AXFixtureNode(role: "AXDocument", value: fixtureAddress)
            case .chromium:
                node = AXFixtureNode(
                    role: "AXTextField",
                    value: fixtureAddress,
                    description: "Address and search bar"
                )
            case .firefox:
                node = AXFixtureNode(
                    role: "AXTextField",
                    value: fixtureAddress,
                    description: "Search with or enter address"
                )
            }
            return BrowserContextFixture(
                family: family,
                bundleID: "fixture.browser.\(family.rawValue)",
                resolvedWindowToken: "window-\(index)",
                observationWindowToken: "window-\(index)",
                isPrivateHint: false,
                nodes: [node]
            )
        }

        return S2FixtureCatalog(
            generatorVersion: "s2-context-fixture-generator-v1",
            seed: seed,
            axFixtures: axFixtures,
            ocrFixtures: ocrFixtures,
            privacyFixtures: privacyFixtures,
            browserFixtures: browserFixtures
        )
    }
}
