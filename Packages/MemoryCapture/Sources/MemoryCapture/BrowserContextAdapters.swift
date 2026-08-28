import ApplicationServices
import Foundation
import MemoryContracts

public enum SupportedBrowser: String, Codable, CaseIterable, Sendable {
    case safari
    case chrome
    case arcDia
    case edge
    case firefox

    public var contractFamily: MemoryContracts.BrowserFamily {
        switch self {
        case .safari: .safari
        case .chrome: .chrome
        case .arcDia: .arc
        case .edge: .edge
        case .firefox: .firefox
        }
    }
}

public struct BrowserAdapterDefinition: Equatable, Sendable {
    public let browser: SupportedBrowser
    public let bundleIdentifiers: [String]
    public let addressRoles: Set<String>
    public let descriptorTerms: [String]
    public let permitsDocumentURL: Bool
    public let privateWindowTerms: [String]

    public init(
        browser: SupportedBrowser,
        bundleIdentifiers: [String],
        addressRoles: Set<String>,
        descriptorTerms: [String],
        permitsDocumentURL: Bool,
        privateWindowTerms: [String]
    ) {
        self.browser = browser
        self.bundleIdentifiers = bundleIdentifiers
        self.addressRoles = addressRoles
        self.descriptorTerms = descriptorTerms
        self.permitsDocumentURL = permitsDocumentURL
        self.privateWindowTerms = privateWindowTerms
    }

    public func fixtureAddressCandidate(value: String) -> BrowserAddressCandidate {
        if permitsDocumentURL {
            return BrowserAddressCandidate(
                role: "AXDocument",
                value: value,
                descriptor: "Document URL",
                isFocused: false
            )
        }
        return BrowserAddressCandidate(
            role: addressRoles.sorted().first ?? "AXTextField",
            value: value,
            descriptor: descriptorTerms.first ?? "Address",
            isFocused: true
        )
    }

    fileprivate func accepts(_ candidate: BrowserAddressCandidate) -> Bool {
        if permitsDocumentURL, candidate.role == "AXDocument" {
            return true
        }
        guard addressRoles.contains(candidate.role) else {
            return false
        }
        let descriptor = candidate.descriptor
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return descriptorTerms.contains { descriptor.contains($0) }
    }
}

public struct BrowserAdapterRegistry: Equatable, Sendable {
    public let adapters: [BrowserAdapterDefinition]

    public init(adapters: [BrowserAdapterDefinition]) {
        self.adapters = adapters
    }

    public func adapter(for bundleIdentifier: String) -> BrowserAdapterDefinition? {
        adapters.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }

    public static let production = BrowserAdapterRegistry(adapters: [
        BrowserAdapterDefinition(
            browser: .safari,
            bundleIdentifiers: [
                "com.apple.Safari",
                "com.apple.SafariTechnologyPreview",
            ],
            addressRoles: ["AXTextField", "AXComboBox"],
            descriptorTerms: ["address", "url", "smart search"],
            permitsDocumentURL: true,
            privateWindowTerms: ["private browsing", "private window"]
        ),
        BrowserAdapterDefinition(
            browser: .chrome,
            bundleIdentifiers: [
                "com.google.Chrome",
                "com.google.Chrome.beta",
                "com.google.Chrome.dev",
                "com.google.Chrome.canary",
            ],
            addressRoles: ["AXTextField", "AXComboBox"],
            descriptorTerms: ["address and search bar", "address", "location"],
            permitsDocumentURL: false,
            privateWindowTerms: ["incognito"]
        ),
        BrowserAdapterDefinition(
            browser: .arcDia,
            bundleIdentifiers: [
                "company.thebrowser.Browser",
                "company.thebrowser.dia",
                "company.thebrowser.Dia",
            ],
            addressRoles: ["AXTextField", "AXComboBox"],
            descriptorTerms: ["address and search bar", "address", "location", "url"],
            permitsDocumentURL: false,
            privateWindowTerms: ["incognito", "private"]
        ),
        BrowserAdapterDefinition(
            browser: .edge,
            bundleIdentifiers: [
                "com.microsoft.edgemac",
                "com.microsoft.edgemac.Beta",
                "com.microsoft.edgemac.Dev",
                "com.microsoft.edgemac.Canary",
            ],
            addressRoles: ["AXTextField", "AXComboBox"],
            descriptorTerms: ["address and search bar", "address", "location"],
            permitsDocumentURL: false,
            privateWindowTerms: ["inprivate"]
        ),
        BrowserAdapterDefinition(
            browser: .firefox,
            bundleIdentifiers: [
                "org.mozilla.firefox",
                "org.mozilla.firefoxdeveloperedition",
                "org.mozilla.nightly",
            ],
            addressRoles: ["AXTextField", "AXComboBox"],
            descriptorTerms: ["search with or enter address", "address", "urlbar", "location"],
            permitsDocumentURL: false,
            privateWindowTerms: ["private browsing", "private window"]
        ),
    ])
}

public struct BrowserResolvedTarget: Equatable, Sendable {
    public let windowID: UInt32
    public let processID: Int32
    public let bundleIdentifier: String
    public let bounds: PointRect

    public init(
        windowID: UInt32,
        processID: Int32,
        bundleIdentifier: String,
        bounds: PointRect
    ) {
        self.windowID = windowID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.bounds = bounds
    }
}

public struct BrowserAddressCandidate: Equatable, Sendable {
    public let role: String
    public let value: String
    public let descriptor: String
    public let isFocused: Bool

    public init(
        role: String,
        value: String,
        descriptor: String,
        isFocused: Bool
    ) {
        self.role = role
        self.value = value
        self.descriptor = descriptor
        self.isFocused = isFocused
    }
}

public enum BrowserPrivateState: String, Codable, Equatable, Sendable {
    case publicContext
    case privateContext
    case unknown
}

public struct BrowserContextObservation: Equatable, Sendable {
    public var target: BrowserResolvedTarget
    public var observedProcessID: Int32
    public var observedWindowBounds: PointRect
    public var windowTitle: String?
    public var privateState: BrowserPrivateState
    public var addressCandidates: [BrowserAddressCandidate]

    public init(
        target: BrowserResolvedTarget,
        observedProcessID: Int32,
        observedWindowBounds: PointRect,
        windowTitle: String?,
        privateState: BrowserPrivateState,
        addressCandidates: [BrowserAddressCandidate]
    ) {
        self.target = target
        self.observedProcessID = observedProcessID
        self.observedWindowBounds = observedWindowBounds
        self.windowTitle = windowTitle
        self.privateState = privateState
        self.addressCandidates = addressCandidates
    }
}

public struct ApprovedBrowserContextOutput: Codable, Equatable, Sendable {
    public let targetWindowID: UInt32
    public let context: MemoryContracts.BrowserContext
    public let serializedURL: String

    public init(
        targetWindowID: UInt32,
        context: MemoryContracts.BrowserContext,
        serializedURL: String
    ) {
        self.targetWindowID = targetWindowID
        self.context = context
        self.serializedURL = serializedURL
    }
}

public struct PrivateBrowserContextOutput: Codable, Equatable, Sendable {
    public let targetWindowID: UInt32
    public let family: MemoryContracts.BrowserFamily
    public let isPrivateContext: Bool

    public init(targetWindowID: UInt32, family: MemoryContracts.BrowserFamily) {
        self.targetWindowID = targetWindowID
        self.family = family
        isPrivateContext = true
    }
}

public enum BrowserContextUnavailableReason: String, Codable, Equatable, Sendable {
    case unsupportedBrowser
    case targetWindowMismatch
    case ambiguousAddressField
    case privateStateUnavailable
    case urlUnavailable
    case unsupportedURL
}

public enum BrowserContextResolution: Equatable, Sendable {
    case approved(ApprovedBrowserContextOutput)
    case privateContext(PrivateBrowserContextOutput)
    case unavailable(BrowserContextUnavailableReason)
}

public struct BrowserAddressFieldAdapter: Sendable {
    public let registry: BrowserAdapterRegistry

    public init(registry: BrowserAdapterRegistry = .production) {
        self.registry = registry
    }

    public func inspect(_ observation: BrowserContextObservation) -> BrowserContextResolution {
        guard let adapter = registry.adapter(for: observation.target.bundleIdentifier) else {
            return .unavailable(.unsupportedBrowser)
        }
        guard observation.target.processID == observation.observedProcessID,
              geometryMatches(observation.target.bounds, observation.observedWindowBounds)
        else {
            return .unavailable(.targetWindowMismatch)
        }
        switch observation.privateState {
        case .privateContext:
            return .privateContext(
                PrivateBrowserContextOutput(
                    targetWindowID: observation.target.windowID,
                    family: adapter.browser.contractFamily
                )
            )
        case .unknown:
            return .unavailable(.privateStateUnavailable)
        case .publicContext:
            break
        }

        let candidates = observation.addressCandidates.filter(adapter.accepts)
        guard !candidates.isEmpty else {
            return .unavailable(.urlUnavailable)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return .unavailable(.ambiguousAddressField)
        }
        guard let normalized = normalize(candidate.value, family: adapter.browser.contractFamily) else {
            return .unavailable(.unsupportedURL)
        }
        return .approved(
            ApprovedBrowserContextOutput(
                targetWindowID: observation.target.windowID,
                context: normalized.context,
                serializedURL: normalized.serializedURL
            )
        )
    }

    private func normalize(
        _ rawValue: String,
        family: MemoryContracts.BrowserFamily
    ) -> (context: MemoryContracts.BrowserContext, serializedURL: String)? {
        guard let components = URLComponents(string: rawValue),
              let rawScheme = components.scheme,
              let rawHost = components.host
        else {
            return nil
        }
        let scheme = rawScheme.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let host = rawHost.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard scheme == "https" || scheme == "http",
              !host.isEmpty,
              host.unicodeScalars.allSatisfy(\.isASCII),
              isPermittedPort(components.port, scheme: scheme)
        else {
            return nil
        }
        let path = normalizedPath(components.percentEncodedPath)
        guard let origin = try? BrowserOrigin(scheme: scheme, host: host, path: path),
              let context = try? MemoryContracts.BrowserContext(
                  family: family,
                  origin: origin,
                  isPrivateContext: false
              )
        else {
            return nil
        }
        return (context, scheme + "://" + host + (path ?? ""))
    }

    private func isPermittedPort(_ port: Int?, scheme: String) -> Bool {
        guard let port else { return true }
        return (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    private func normalizedPath(_ encodedPath: String) -> String? {
        guard !encodedPath.isEmpty, encodedPath != "/" else {
            return nil
        }
        let lowercased = encodedPath.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard encodedPath.hasPrefix("/"),
              !encodedPath.contains("?"),
              !encodedPath.contains("#"),
              !encodedPath.contains("@"),
              !encodedPath.contains("\\"),
              !lowercased.contains("/%2e"),
              !encodedPath.split(separator: "/").contains("..")
        else {
            return nil
        }
        return encodedPath
    }

    private func geometryMatches(_ lhs: PointRect, _ rhs: PointRect) -> Bool {
        let edgeDeltasMatch = abs(lhs.x - rhs.x) <= 4
            && abs(lhs.y - rhs.y) <= 4
            && abs((lhs.x + lhs.width) - (rhs.x + rhs.width)) <= 4
            && abs((lhs.y + lhs.height) - (rhs.y + rhs.height)) <= 4
        if edgeDeltasMatch { return true }
        let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        let intersection = width * height
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 && intersection / union >= 0.90
    }
}

public struct SystemBrowserContextInspector: Sendable {
    public let registry: BrowserAdapterRegistry

    public init(registry: BrowserAdapterRegistry = .production) {
        self.registry = registry
    }

    public func inspect(_ foreground: ForegroundCaptureResolution) async -> BrowserContextResolution {
        guard let target = foreground.target,
              case let .available(application, focusedWindow) = foreground.snapshot,
              target.processID == application.processID,
              focusedWindow.processID == application.processID
        else {
            return .unavailable(.targetWindowMismatch)
        }
        guard let adapter = registry.adapter(for: application.bundleIdentifier) else {
            return .unavailable(.unsupportedBrowser)
        }
        let resolvedTarget = BrowserResolvedTarget(
            windowID: target.windowID,
            processID: target.processID,
            bundleIdentifier: application.bundleIdentifier,
            bounds: target.bounds
        )
        let observation = await Task.detached(priority: .userInitiated) {
            readBrowserObservation(
                target: resolvedTarget,
                adapter: adapter,
                fallbackTitle: focusedWindow.title
            )
        }.value
        guard let observation else {
            return .unavailable(.targetWindowMismatch)
        }
        return BrowserAddressFieldAdapter(registry: registry).inspect(observation)
    }
}

public struct LM021BrowserFixtureCase: Equatable, Sendable {
    public let id: String
    public let observation: BrowserContextObservation
    public let expectedResolution: BrowserContextResolution
    public let expectedHost: String?
}

public enum LM021BrowserContextFixture: Sendable {
    public static func make(seed: UInt64) -> [LM021BrowserFixtureCase] {
        let registry = BrowserAdapterRegistry.production
        let rotation = Int(seed % UInt64(SupportedBrowser.allCases.count))
        func adapter(_ index: Int) -> BrowserAdapterDefinition {
            let browser = SupportedBrowser.allCases[(index + rotation) % SupportedBrowser.allCases.count]
            return registry.adapters.first { $0.browser == browser }!
        }
        func observation(
            index: Int,
            rawURL: String,
            privateState: BrowserPrivateState = .publicContext
        ) -> BrowserContextObservation {
            let definition = adapter(index)
            let bounds = PointRect(x: 100 + Double(index % 7), y: 80, width: 900, height: 640)
            return BrowserContextObservation(
                target: BrowserResolvedTarget(
                    windowID: UInt32(30_000 + index),
                    processID: Int32(4_000 + index),
                    bundleIdentifier: definition.bundleIdentifiers.first!,
                    bounds: bounds
                ),
                observedProcessID: Int32(4_000 + index),
                observedWindowBounds: bounds,
                windowTitle: "Approved fixture window \(index)",
                privateState: privateState,
                addressCandidates: [definition.fixtureAddressCandidate(value: rawURL)]
            )
        }

        var fixtures: [LM021BrowserFixtureCase] = []
        for index in 0 ..< 480 {
            let host = "fixture-\(index).example.test"
            let rawURL = "https" + "://user:credential-sentinel@\(host)/safe/path"
                + "?token=query-sentinel#fragment-sentinel"
            let value = observation(index: index, rawURL: rawURL)
            let family = adapter(index).browser.contractFamily
            let origin = try! BrowserOrigin(scheme: "https", host: host, path: "/safe/path")
            let context = try! MemoryContracts.BrowserContext(
                family: family,
                origin: origin,
                isPrivateContext: false
            )
            fixtures.append(
                LM021BrowserFixtureCase(
                    id: "approved-\(String(format: "%03d", index))",
                    observation: value,
                    expectedResolution: .approved(
                        ApprovedBrowserContextOutput(
                            targetWindowID: value.target.windowID,
                            context: context,
                            serializedURL: "https" + "://\(host)/safe/path"
                        )
                    ),
                    expectedHost: host
                )
            )
        }
        for offset in 0 ..< 30 {
            let index = 480 + offset
            let value = observation(
                index: index,
                rawURL: "https" + "://private.example.test/SENSITIVE_PRIVATE_SENTINEL",
                privateState: .privateContext
            )
            fixtures.append(
                LM021BrowserFixtureCase(
                    id: "private-\(String(format: "%03d", offset))",
                    observation: value,
                    expectedResolution: .privateContext(
                        PrivateBrowserContextOutput(
                            targetWindowID: value.target.windowID,
                            family: adapter(index).browser.contractFamily
                        )
                    ),
                    expectedHost: nil
                )
            )
        }
        for offset in 0 ..< 30 {
            let index = 510 + offset
            var value = observation(index: index, rawURL: "https" + "://mismatch.example.test/")
            value.observedProcessID += 1
            fixtures.append(
                LM021BrowserFixtureCase(
                    id: "target-mismatch-\(String(format: "%03d", offset))",
                    observation: value,
                    expectedResolution: .unavailable(.targetWindowMismatch),
                    expectedHost: nil
                )
            )
        }
        for offset in 0 ..< 15 {
            let index = 540 + offset
            var value = observation(index: index, rawURL: "https" + "://ambiguous.example.test/")
            value.addressCandidates.append(value.addressCandidates[0])
            fixtures.append(
                LM021BrowserFixtureCase(
                    id: "ambiguous-\(String(format: "%03d", offset))",
                    observation: value,
                    expectedResolution: .unavailable(.ambiguousAddressField),
                    expectedHost: nil
                )
            )
        }
        for offset in 0 ..< 15 {
            let index = 555 + offset
            let value = observation(
                index: index,
                rawURL: "https" + "://unknown.example.test/",
                privateState: .unknown
            )
            fixtures.append(
                LM021BrowserFixtureCase(
                    id: "private-unknown-\(String(format: "%03d", offset))",
                    observation: value,
                    expectedResolution: .unavailable(.privateStateUnavailable),
                    expectedHost: nil
                )
            )
        }
        for offset in 0 ..< 15 {
            let index = 570 + offset
            let value = observation(index: index, rawURL: "file:///private/sentinel")
            fixtures.append(
                LM021BrowserFixtureCase(
                    id: "unsupported-url-\(String(format: "%03d", offset))",
                    observation: value,
                    expectedResolution: .unavailable(.unsupportedURL),
                    expectedHost: nil
                )
            )
        }
        for offset in 0 ..< 15 {
            let index = 585 + offset
            var value = observation(index: index, rawURL: "https" + "://missing.example.test/")
            value.addressCandidates = []
            fixtures.append(
                LM021BrowserFixtureCase(
                    id: "url-unavailable-\(String(format: "%03d", offset))",
                    observation: value,
                    expectedResolution: .unavailable(.urlUnavailable),
                    expectedHost: nil
                )
            )
        }
        return fixtures
    }
}

private func readBrowserObservation(
    target: BrowserResolvedTarget,
    adapter: BrowserAdapterDefinition,
    fallbackTitle: String?
) -> BrowserContextObservation? {
    let applicationElement = AXUIElementCreateApplication(target.processID)
    AXUIElementSetMessagingTimeout(applicationElement, 0.05)
    guard let window: AXUIElement = browserAXAttribute(applicationElement, kAXFocusedWindowAttribute)
    else {
        return nil
    }
    var processID: pid_t = 0
    guard AXUIElementGetPid(window, &processID) == .success,
          processID == target.processID,
          let bounds = browserAXBounds(window)
    else {
        return nil
    }
    let title: String? = browserAXStringAttribute(window, kAXTitleAttribute) ?? fallbackTitle
    let privateState = classifyPrivateState(title: title, adapter: adapter)
    guard privateState == .publicContext else {
        return BrowserContextObservation(
            target: target,
            observedProcessID: processID,
            observedWindowBounds: bounds,
            windowTitle: nil,
            privateState: privateState,
            addressCandidates: []
        )
    }
    var candidates: [BrowserAddressCandidate] = []
    var stack: [(AXUIElement, Int)] = [(window, 0)]
    var visited = 0
    while let (element, depth) = stack.popLast(), visited < 256 {
        visited += 1
        let role: String = browserAXAttribute(element, kAXRoleAttribute) ?? ""
        let descriptor = [
            browserAXStringAttribute(element, kAXDescriptionAttribute),
            browserAXStringAttribute(element, kAXIdentifierAttribute),
            browserAXStringAttribute(element, kAXHelpAttribute),
            browserAXStringAttribute(element, kAXTitleAttribute),
        ].compactMap { $0 }.joined(separator: " ")
        let value = browserAXStringAttribute(element, kAXURLAttribute)
            ?? browserAXStringAttribute(element, kAXValueAttribute)
        if let value {
            let candidate = BrowserAddressCandidate(
                role: role,
                value: value,
                descriptor: descriptor,
                isFocused: browserAXAttribute(element, kAXFocusedAttribute) ?? false
            )
            if adapter.accepts(candidate) {
                candidates.append(candidate)
            }
        }
        if depth < 12,
           let children: [AXUIElement] = browserAXAttribute(element, kAXChildrenAttribute)
        {
            children.reversed().forEach { stack.append(($0, depth + 1)) }
        }
    }
    return BrowserContextObservation(
        target: target,
        observedProcessID: processID,
        observedWindowBounds: bounds,
        windowTitle: title,
        privateState: privateState,
        addressCandidates: candidates
    )
}

private func classifyPrivateState(
    title: String?,
    adapter: BrowserAdapterDefinition
) -> BrowserPrivateState {
    guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .unknown
    }
    let normalized = title.lowercased(with: Locale(identifier: "en_US_POSIX"))
    return adapter.privateWindowTerms.contains { normalized.contains($0) }
        ? .privateContext
        : .publicContext
}

private func browserAXStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value
    else {
        return nil
    }
    if let string = value as? String {
        return string
    }
    if let url = value as? URL {
        return url.absoluteString
    }
    return nil
}

private func browserAXBounds(_ element: AXUIElement) -> PointRect? {
    guard let positionValue: AXValue = browserAXAttribute(element, kAXPositionAttribute),
          let sizeValue: AXValue = browserAXAttribute(element, kAXSizeAttribute)
    else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &position),
          AXValueGetValue(sizeValue, .cgSize, &size),
          size.width > 0,
          size.height > 0
    else {
        return nil
    }
    return PointRect(x: position.x, y: position.y, width: size.width, height: size.height)
}

private func browserAXAttribute<Value>(_ element: AXUIElement, _ attribute: String) -> Value? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? Value
}
