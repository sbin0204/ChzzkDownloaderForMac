import AppKit
import SwiftUI

enum AppWindowIdentifiers {
    static let main = NSUserInterfaceItemIdentifier("com.chzzkdownloader.main-window")
}

enum AppWindowPresenter {
    @discardableResult
    static func revealMainWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier == AppWindowIdentifiers.main }) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

struct WindowIdentifierMarker: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier
    var hidesOnClose = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        assignWindowProperties(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        assignWindowProperties(from: nsView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func assignWindowProperties(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = identifier
            if hidesOnClose {
                coordinator.hidesOnClose = true
                window.delegate = coordinator
            }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var hidesOnClose = false

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard hidesOnClose else { return true }
            sender.orderOut(nil)
            return false
        }
    }
}
