import AppKit
import Foundation
import MemoryDesignSystem

@main
struct MemorySnapshotTool {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard let repositoryIndex = arguments.firstIndex(of: "--repository-root"),
              arguments.indices.contains(repositoryIndex + 1),
              let outputIndex = arguments.firstIndex(of: "--output-root"),
              arguments.indices.contains(outputIndex + 1)
        else {
            throw SnapshotToolError.usage
        }

        let repositoryRoot = URL(
            fileURLWithPath: arguments[repositoryIndex + 1],
            isDirectory: true
        ).standardizedFileURL
        let outputRoot = URL(
            fileURLWithPath: arguments[outputIndex + 1],
            isDirectory: true
        ).standardizedFileURL
        guard repositoryRoot.appending(path: "Docs/Plan/11-ux-specification.md").existsOnDisk else {
            throw SnapshotToolError.invalidRepositoryRoot
        }
        let resultsRelativePath = "Results/LM-013"
        let baselineRelativePath = "\(resultsRelativePath)/Baselines"
        let baselineDirectory = outputRoot.appending(path: baselineRelativePath)
        try FileManager.default.createDirectory(
            at: baselineDirectory,
            withIntermediateDirectories: true
        )

        _ = NSApplication.shared
        let renderer = MemorySnapshotRenderer()
        var artifacts: [MemorySnapshotArtifact] = []
        for configuration in MemorySnapshotConfiguration.canonicalMatrix {
            let data = try renderer.pngData(
                of: MemoryComponentBaselineBoard(),
                configuration: configuration
            )
            let relativePath = "\(baselineRelativePath)/\(configuration.fileStem).png"
            try data.write(to: outputRoot.appending(path: relativePath), options: .atomic)
            artifacts.append(
                MemorySnapshotArtifact(
                    configuration: configuration,
                    path: relativePath,
                    sha256: MemorySnapshotManifest.sha256(data),
                    sizeBytes: data.count,
                    pixelWidth: configuration.pixelWidth,
                    pixelHeight: configuration.pixelHeight
                )
            )
        }

        let manifest = MemorySnapshotManifest(
            configurations: MemorySnapshotConfiguration.canonicalMatrix,
            artifacts: artifacts
        )
        let resultsDirectory = outputRoot.appending(path: resultsRelativePath)
        try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        try manifest.canonicalJSON().write(
            to: resultsDirectory.appending(path: "snapshot-manifest.json"),
            options: .atomic
        )
        try Data(indexHTML(artifacts: artifacts).utf8).write(
            to: resultsDirectory.appending(path: "snapshot-index.html"),
            options: .atomic
        )

        guard try manifest.verifyArtifacts(relativeTo: outputRoot) else {
            throw SnapshotToolError.generatedArtifactsFailedVerification
        }
        print("rendered \(artifacts.count) verified deterministic baselines")
    }

    private static func indexHTML(artifacts: [MemorySnapshotArtifact]) -> String {
        let figures = artifacts.map { artifact in
            let filename = URL(fileURLWithPath: artifact.path).lastPathComponent
            let configuration = artifact.configuration
            return """
              <figure data-path="\(artifact.path)">
                <a href="Baselines/\(filename)"><img src="Baselines/\(filename)" alt="Shared controls at \(configuration.size.name) size, \(configuration.appearance.rawValue), \(Int(configuration.scale))x"></a>
                <figcaption>\(configuration.size.name) · \(configuration.appearance.rawValue) · \(Int(configuration.scale))× · \(artifact.pixelWidth)×\(artifact.pixelHeight)</figcaption>
              </figure>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>LM-013 Shared Control Baselines</title>
          <style>
            body { font: 14px -apple-system, sans-serif; margin: 24px; background: Canvas; color: CanvasText; }
            h1 { font-size: 22px; }
            p { max-width: 72ch; }
            main { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 24px; }
            figure { margin: 0; border: 1px solid GrayText; border-radius: 10px; padding: 12px; }
            img { width: 100%; height: auto; display: block; }
            figcaption { margin-top: 8px; color: GrayText; }
          </style>
        </head>
        <body>
          <h1>LM-013 shared control baselines</h1>
          <p>Locally rendered synthetic fixtures. Each approved image is pinned by <code>snapshot-manifest.json</code>; the verification command rerenders all images and requires byte-for-byte equality.</p>
          <main>
        \(figures)
          </main>
        </body>
        </html>
        """ + "\n"
    }
}

private enum SnapshotToolError: Error {
    case usage
    case invalidRepositoryRoot
    case generatedArtifactsFailedVerification
}

private extension URL {
    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
