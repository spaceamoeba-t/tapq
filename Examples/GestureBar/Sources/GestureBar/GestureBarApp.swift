import AppKit
import SwiftUI
import TapQGestures

@main
struct GestureBarApp: App {
    @State private var model = GestureBarModel()

    var body: some Scene {
        MenuBarExtra("GestureBar", systemImage: "waveform") {
            MenuContent(model: model)
                .padding(12)
                .frame(width: 260)
        }
        // The window style keeps the SwiftUI content live while the menu is open, which
        // the plain menu style does not.
        .menuBarExtraStyle(.window)
    }
}

/// Owns the one session and the last few events it produced.
///
/// Everything here is main-actor because `GestureSession` is: samples arrive on the main
/// actor and the detectors they feed are main-actor state.
@MainActor
@Observable
final class GestureBarModel {
    private(set) var capabilities = GestureCapabilities.current()
    private(set) var isRunning = false
    private(set) var recentEvents: [String] = []

    private var session: GestureSession?
    private var eventTask: Task<Void, Never>?

    private static let retainedEventCount = 5

    /// Capabilities are a live query, not a snapshot: connecting AirPods after launch
    /// changes the answer, so the menu re-reads them each time it opens.
    func refreshCapabilities() {
        capabilities = .current()
    }

    func start() {
        guard !isRunning else { return }
        let session = GestureSession(
            configuration: .calibrated(from: CalibrationStore.defaultStore())
        )
        self.session = session
        isRunning = true
        eventTask = Task {
            for await event in session.events() {
                append(event)
            }
            isRunning = false
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        session?.stop()
        session = nil
        isRunning = false
    }

    private func append(_ event: GestureEvent) {
        recentEvents.append(Self.describe(event))
        if recentEvents.count > Self.retainedEventCount {
            recentEvents.removeFirst(recentEvents.count - Self.retainedEventCount)
        }
    }

    private static func describe(_ event: GestureEvent) -> String {
        switch event {
        case .headGesture(.nod): return "nod"
        case .headGesture(.shake): return "shake"
        case .tap: return "tap"
        case .tilt(.tiltLeft): return "tilt left"
        case .tilt(.tiltRight): return "tilt right"
        case .motionSwipe(let direction): return "motion swipe \(direction)"
        case .volumeSwipe(let direction): return "volume swipe \(direction)"
        case .motionLost(let reason): return "motion lost (\(reason.rawValue))"
        case .motionRestored: return "motion restored"
        // `GestureEvent` is not frozen: a case added in a later release must render as
        // something rather than fail to build here.
        @unknown default: return "unrecognized event"
        }
    }
}

private struct MenuContent: View {
    let model: GestureBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capabilities")
                .font(.headline)
            capabilityRow("Headphone motion", model.capabilities.headphoneMotion)
            capabilityRow("Volume swipes", model.capabilities.volumeSwipes)
            capabilityRow("Motion swipes", model.capabilities.motionSwipes)

            Divider()

            Button(model.isRunning ? "Stop" : "Start") {
                if model.isRunning {
                    model.stop()
                } else {
                    model.start()
                }
            }
            .disabled(!model.capabilities.headphoneMotion && !model.isRunning)

            Divider()

            Text("Recent events")
                .font(.headline)
            if model.recentEvents.isEmpty {
                Text(model.isRunning ? "Waiting for a gesture." : "Not listening.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.recentEvents.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .onAppear { model.refreshCapabilities() }
    }

    private func capabilityRow(_ label: String, _ available: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(available ? "yes" : "no")
                .foregroundStyle(available ? Color.primary : Color.secondary)
        }
    }
}
