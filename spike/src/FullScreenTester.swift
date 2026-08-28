import AppKit

// A separate, ordinary app that shoves itself into a native full-screen space.
// This is the real test: the spike panel has to draw over ANOTHER app's
// full-screen space, which is the case that historically breaks.

final class TesterDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Full Screen Tester"
        window.collectionBehavior.insert(.fullScreenPrimary)

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemIndigo.cgColor

        let text = NSTextField(labelWithString: "FULL SCREEN TESTER\nthe floating pill should still be visible")
        text.font = .systemFont(ofSize: 34, weight: .bold)
        text.textColor = .white
        text.alignment = .center
        text.maximumNumberOfLines = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            text.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Give the window server a beat, then go full screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.window.toggleFullScreen(nil)
            print("[tester] toggled full screen")
            fflush(stdout)
        }
    }
}

let app = NSApplication.shared
let delegate = TesterDelegate()
app.delegate = delegate
app.run()
