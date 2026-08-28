import AppKit
import CryptoKit
import Foundation
import SwiftUI

public enum MemorySnapshotAppearance: String, CaseIterable, Codable, Hashable, Sendable {
    case light
    case dark
    case increasedContrast = "increased-contrast"

    var appKitName: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        case .increasedContrast: .accessibilityHighContrastAqua
        }
    }

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }
}

public struct MemorySnapshotSize: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let width: Double
    public let height: Double

    private init(name: String, width: Double, height: Double) {
        self.name = name
        self.width = width
        self.height = height
    }

    public static let `default` = MemorySnapshotSize(
        name: "default",
        width: Double(MainWindowDefaults.defaultWidth),
        height: Double(MainWindowDefaults.defaultHeight)
    )
    public static let minimum = MemorySnapshotSize(
        name: "minimum",
        width: Double(MainWindowDefaults.minimumWidth),
        height: Double(MainWindowDefaults.minimumHeight)
    )

    public static func custom(width: Double, height: Double, name: String) -> MemorySnapshotSize {
        MemorySnapshotSize(name: name, width: width, height: height)
    }
}

public enum MemorySnapshotConfigurationError: Error, Equatable {
    case invalidName
    case invalidSize
    case unsupportedScale
}

public struct MemorySnapshotConfiguration: Codable, Equatable, Hashable, Sendable {
    public let size: MemorySnapshotSize
    public let appearance: MemorySnapshotAppearance
    public let scale: Double

    public init(size: MemorySnapshotSize, appearance: MemorySnapshotAppearance, scale: Double) {
        self.size = size
        self.appearance = appearance
        self.scale = scale
    }

    public static func validated(
        size: MemorySnapshotSize,
        appearance: MemorySnapshotAppearance,
        scale: Double
    ) throws -> MemorySnapshotConfiguration {
        guard !size.name.isEmpty,
              size.name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw MemorySnapshotConfigurationError.invalidName
        }
        guard size.width > 0, size.height > 0 else {
            throw MemorySnapshotConfigurationError.invalidSize
        }
        guard scale == 1 || scale == 2 else {
            throw MemorySnapshotConfigurationError.unsupportedScale
        }
        return MemorySnapshotConfiguration(size: size, appearance: appearance, scale: scale)
    }

    public var logicalWidth: Double { size.width }
    public var logicalHeight: Double { size.height }
    public var pixelWidth: Int { Int(logicalWidth * scale) }
    public var pixelHeight: Int { Int(logicalHeight * scale) }
    public var fileStem: String {
        "shared-controls-\(size.name)-\(appearance.rawValue)-\(Int(scale))x"
    }

    public static let canonicalMatrix: [MemorySnapshotConfiguration] = [
        MemorySnapshotSize.default,
        .minimum,
    ].flatMap { size in
        MemorySnapshotAppearance.allCases.flatMap { appearance in
            [1.0, 2.0].map { scale in
                MemorySnapshotConfiguration(size: size, appearance: appearance, scale: scale)
            }
        }
    }
}

@MainActor
public struct MemorySnapshotRenderer {
    public init() {}

    public func pngData<Content: View>(
        of content: Content,
        configuration: MemorySnapshotConfiguration
    ) throws -> Data {
        let validated = try MemorySnapshotConfiguration.validated(
            size: configuration.size,
            appearance: configuration.appearance,
            scale: configuration.scale
        )
        let logicalSize = NSSize(
            width: validated.logicalWidth,
            height: validated.logicalHeight
        )
        let appearance = NSAppearance(named: validated.appearance.appKitName)
        let root = MemorySnapshotRoot(
            content: content,
            configuration: validated
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: logicalSize)
        hostingView.appearance = appearance
        hostingView.wantsLayer = true
        hostingView.layer?.contentsScale = validated.scale

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: logicalSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: validated.pixelWidth,
            pixelsHigh: validated.pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw MemorySnapshotRendererError.bitmapAllocationFailed
        }
        bitmap.size = logicalSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        window.contentView = nil
        window.close()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw MemorySnapshotRendererError.pngEncodingFailed
        }
        return data
    }
}

public enum MemorySnapshotRendererError: Error, Equatable {
    case bitmapAllocationFailed
    case pngEncodingFailed
}

private struct MemorySnapshotRoot<Content: View>: View {
    let content: Content
    let configuration: MemorySnapshotConfiguration

    var body: some View {
        content
            .frame(
                width: configuration.logicalWidth,
                height: configuration.logicalHeight
            )
            .environment(\.colorScheme, configuration.appearance.colorScheme)
            .memoryPreviewAccessibility(
                reduceMotion: true,
                increasedContrast: configuration.appearance == .increasedContrast
            )
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

public struct MemorySnapshotArtifact: Codable, Equatable, Hashable, Sendable {
    public let configuration: MemorySnapshotConfiguration
    public let path: String
    public let sha256: String
    public let sizeBytes: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        configuration: MemorySnapshotConfiguration,
        path: String,
        sha256: String,
        sizeBytes: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.configuration = configuration
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct MemorySnapshotManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let renderer: String
    public let configurations: [MemorySnapshotConfiguration]
    public let artifacts: [MemorySnapshotArtifact]

    public init(
        schemaVersion: Int = 1,
        renderer: String = "NSHostingView/cacheDisplay/PNG",
        configurations: [MemorySnapshotConfiguration],
        artifacts: [MemorySnapshotArtifact]
    ) {
        self.schemaVersion = schemaVersion
        self.renderer = renderer
        self.configurations = configurations
        self.artifacts = artifacts
    }

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public func verifyArtifacts(relativeTo root: URL) throws -> Bool {
        guard configurations == MemorySnapshotConfiguration.canonicalMatrix,
              artifacts.count == configurations.count,
              Set(artifacts.map(\.configuration)) == Set(configurations)
        else {
            return false
        }
        for artifact in artifacts {
            guard !artifact.path.hasPrefix("/"),
                  !artifact.path.split(separator: "/").contains("..")
            else {
                return false
            }
            let data = try Data(contentsOf: root.appending(path: artifact.path))
            guard data.count == artifact.sizeBytes,
                  Self.sha256(data) == artifact.sha256,
                  let bitmap = NSBitmapImageRep(data: data),
                  bitmap.pixelsWide == artifact.pixelWidth,
                  bitmap.pixelsHigh == artifact.pixelHeight,
                  artifact.pixelWidth == artifact.configuration.pixelWidth,
                  artifact.pixelHeight == artifact.configuration.pixelHeight
            else {
                return false
            }
        }
        return true
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
