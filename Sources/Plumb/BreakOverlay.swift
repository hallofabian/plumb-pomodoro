import AppKit
import SwiftUI

/// Optional full-screen card shown when a work interval ends, so the break
/// actually happens. Esc or "dismiss" closes it; it closes itself when work resumes.
@MainActor
final class BreakOverlay {
    static let shared = BreakOverlay()
    private var windows: [NSWindow] = []

    var isVisible: Bool { !windows.isEmpty }

    func show(services: Services) {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = TE.nsCanvas.withAlphaComponent(0.97)
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.onEscape = { [weak self] in self?.hide() }
            let main = screen == NSScreen.main
            window.contentView = NSHostingView(rootView: BreakCard(services: services, showControls: main) { [weak self] in self?.hide() })
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            if main { window.makeKey() }
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

private final class OverlayWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private struct BreakCard: View {
    let services: Services
    let showControls: Bool
    let dismiss: () -> Void

    var body: some View {
        let engine = services.engine
        VStack(alignment: .leading, spacing: TE.s3) {
            HStack(spacing: 6) {
                LED(on: engine.isRunning)
                Code(engine.isRunning ? "\(engine.phase.label) running" : engine.phase.label, color: TE.ink)
            }
            Text(formatClock(engine.remaining))
                .font(TE.numeral(160))
                .foregroundStyle(TE.ink)
                .padding(.leading, -8)
            Text("Step away from the screen. Stand up, look into the distance, drink some water.")
                .font(TE.heading())
                .foregroundStyle(TE.inkSecondary)
            if showControls {
                HStack(spacing: TE.s1) {
                    if engine.status == .idle {
                        Button("start break") { engine.start() }.teButton(.primary)
                    }
                    Button("end break, back to work") {
                        engine.skip()
                        dismiss()
                    }
                    .teButton()
                    if engine.canExtend {
                        Button("+\(services.store.settings.extendMinutes) min work") {
                            engine.extend(minutes: services.store.settings.extendMinutes)
                            dismiss()
                        }
                        .teButton()
                    }
                    Button("dismiss") { dismiss() }.teButton(.text).keyboardShortcut(.cancelAction)
                }
                .padding(.top, TE.s2)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(TE.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
