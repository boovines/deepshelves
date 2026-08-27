import MemoryContracts
import SwiftUI

@main
struct LocalMemoryApp: App {
    var body: some Scene {
        WindowGroup("Local Memory") {
            BootstrapView(schemaVersion: BootstrapContract.schemaVersion)
        }
        .defaultSize(width: 720, height: 480)
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

