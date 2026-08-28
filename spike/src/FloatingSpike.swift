import AppKit

// Spike goal: prove a borderless panel can sit above everything, including
// another app's full-screen space, and survive Space switches.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var label: NSTextField!
    var levelLabel: NSTextField!
    var statusItem: NSStatusItem!
    var timer: Timer?
    let started = Date()

    // Cycle through these to find the one that actually wins.
    let levels: [(name: String, level: NSWindow.Level)] = [
        ("floating",    .floating),
        ("statusBar",   .statusBar),
        ("popUpMenu",   .popUpMenu),
        ("screenSaver", .screenSaver),
    ]
    var levelIndex = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        // .accessory = no Dock icon, no app switcher entry, never steals focus.
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        buildStatusItem()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        report()
    }

    func buildPanel() {
        let size = NSSize(width: 168, height: 56)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = levels[levelIndex].level
        // The three that matter: follow across Spaces, draw over full-screen
        // apps, and don't slide away during Mission Control.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.animationBehavior = .none

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        label = NSTextField(labelWithString: "00:00.0")
        label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        label.alignment = .center
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        levelLabel = NSTextField(labelWithString: levels[levelIndex].name)
        levelLabel.font = .systemFont(ofSize: 9, weight: .medium)
        levelLabel.alignment = .center
        levelLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        levelLabel.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(label)
        blur.addSubview(levelLabel)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            label.topAnchor.constraint(equalTo: blur.topAnchor, constant: 7),
            levelLabel.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            levelLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
        ])

        panel.contentView = blur

        // Park it top-right, just under the menu bar.
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24,
                                         y: vf.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◉"
        let menu = NSMenu()
        for (i, entry) in levels.enumerated() {
            let item = NSMenuItem(title: "Level: \(entry.name)",
                                  action: #selector(pickLevel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = (i == levelIndex) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Spike", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func pickLevel(_ sender: NSMenuItem) {
        levelIndex = sender.tag
        panel.level = levels[levelIndex].level
        levelLabel.stringValue = levels[levelIndex].name
        panel.orderFrontRegardless()
        for item in statusItem.menu?.items ?? [] where item.action == #selector(pickLevel(_:)) {
            item.state = (item.tag == levelIndex) ? .on : .off
        }
        report()
    }

    @objc func quit() { NSApp.terminate(nil) }

    func tick() {
        let t = Date().timeIntervalSince(started)
        label.stringValue = String(format: "%02d:%02d.%01d",
                                   Int(t) / 60, Int(t) % 60, Int(t * 10) % 10)
    }

    func report() {
        let l = levels[levelIndex]
        print("[spike] level=\(l.name) rawValue=\(l.level.rawValue) "
            + "collectionBehavior=\(panel.collectionBehavior.rawValue) "
            + "onActiveSpace=\(panel.isOnActiveSpace) visible=\(panel.isVisible)")
        fflush(stdout)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
