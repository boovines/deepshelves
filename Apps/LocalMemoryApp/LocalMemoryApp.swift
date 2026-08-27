import AppKit
import Darwin
import Foundation
import MemoryCapture
import MemoryContracts
import MemoryEnrichment
import SwiftUI

@main
struct LocalMemoryApp: App {
    private let capabilityProbeOutput: String?
    private let shouldRequestCapturePermissions: Bool
    private let captureSpikeOutputDirectory: String?
    private let captureSpikeDurationSeconds: Double
    private let captureSpikeStaticMode: Bool
    private let captureSpikeCrashActiveMode: Bool
    private let contextSpikeOutputDirectory: String?
    private let vectorSpikeArguments: (output: String, imageModel: String, textModel: String)?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        shouldRequestCapturePermissions = arguments.contains("--request-capture-permissions")
        captureSpikeStaticMode = arguments.contains("--capture-spike-static")
        captureSpikeCrashActiveMode = arguments.contains("--capture-spike-crash-active")
        if let flagIndex = arguments.firstIndex(of: "--context-spike"),
           arguments.indices.contains(flagIndex + 1)
        {
            contextSpikeOutputDirectory = arguments[flagIndex + 1]
        } else {
            contextSpikeOutputDirectory = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--s3-s4-spike"),
           arguments.indices.contains(flagIndex + 3)
        {
            vectorSpikeArguments = (
                arguments[flagIndex + 1],
                arguments[flagIndex + 2],
                arguments[flagIndex + 3]
            )
        } else {
            vectorSpikeArguments = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--capture-spike"),
           arguments.indices.contains(flagIndex + 1)
        {
            captureSpikeOutputDirectory = arguments[flagIndex + 1]
        } else {
            captureSpikeOutputDirectory = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--capture-spike-duration"),
           arguments.indices.contains(flagIndex + 1)
        {
            captureSpikeDurationSeconds = Double(arguments[flagIndex + 1]) ?? 10
        } else {
            captureSpikeDurationSeconds = 10
        }
        if let flagIndex = arguments.firstIndex(of: "--capture-capability-probe"),
           arguments.indices.contains(flagIndex + 1)
        {
            capabilityProbeOutput = arguments[flagIndex + 1]
        } else {
            capabilityProbeOutput = nil
        }
        if let vectorSpikeArguments {
            Self.launchVectorSpike(vectorSpikeArguments)
        }
    }

    var body: some Scene {
        WindowGroup("Local Memory") {
            Group {
                if contextSpikeOutputDirectory != nil {
                    ContextSpikeTargetView()
                } else if captureSpikeOutputDirectory == nil {
                    BootstrapView(schemaVersion: BootstrapContract.schemaVersion)
                } else {
                    CaptureSpikeTargetView(animated: captureSpikeCrashActiveMode)
                }
            }
                .task {
                    if let contextSpikeOutputDirectory {
                        await ContextSpikeHarness.run(
                            outputDirectory: URL(fileURLWithPath: contextSpikeOutputDirectory)
                        )
                        return
                    }
                    if shouldRequestCapturePermissions {
                        _ = CaptureCapabilities.requestFromUser()
                        return
                    }
                    if let captureSpikeOutputDirectory {
                        await CaptureSpikeHarness.run(
                            outputDirectory: URL(fileURLWithPath: captureSpikeOutputDirectory),
                            durationSeconds: captureSpikeDurationSeconds,
                            staticMode: captureSpikeStaticMode
                        )
                        return
                    }
                    guard let capabilityProbeOutput else {
                        return
                    }
                    do {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let data = try encoder.encode(CaptureCapabilities.current())
                        try data.write(to: URL(fileURLWithPath: capabilityProbeOutput), options: .atomic)
                    } catch {
                        FileHandle.standardError.write(Data("capture capability probe failed\n".utf8))
                    }
                    NSApplication.shared.terminate(nil)
                }
        }
        .defaultSize(width: 720, height: 480)
    }

    private static func launchVectorSpike(
        _ arguments: (output: String, imageModel: String, textModel: String)
    ) {
        Task.detached(priority: .userInitiated) {
            let output = URL(fileURLWithPath: arguments.output, isDirectory: true)
            do {
                _ = try await S3S4SpikeRunner.run(
                    outputDirectory: output,
                    referenceImageModelURL: URL(
                        fileURLWithPath: arguments.imageModel,
                        isDirectory: true
                    ),
                    referenceTextModelURL: URL(
                        fileURLWithPath: arguments.textModel,
                        isDirectory: true
                    )
                )
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                try? FileManager.default.createDirectory(
                    at: output,
                    withIntermediateDirectories: true
                )
                try? Data("S3/S4 spike failed: \(error)\n".utf8).write(
                    to: output.appending(path: "s3-s4-error.log"),
                    options: .atomic
                )
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }
}

struct BootstrapView: View {
    let schemaVersion: Int

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.clock")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Local Memory")
                .font(.largeTitle)
                .accessibilityIdentifier("bootstrap.title")
            Text("Your history stays on this Mac.")
                .foregroundStyle(.secondary)
            Text("Bootstrap contract v\(schemaVersion)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 640, minHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bootstrap.root")
    }
}
