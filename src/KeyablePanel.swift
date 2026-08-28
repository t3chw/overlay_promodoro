import AppKit

/// A borderless panel that will accept keyboard input.
///
/// `NSWindow.canBecomeKey` returns false for borderless windows, and NSPanel
/// does not override it. The consequence is subtle and total: a text field
/// inside such a panel can become first responder and show a caret, but the
/// window is never key, so no keystroke is ever routed to it — the field looks
/// live and silently does nothing. Overriding this is the standard fix.
///
/// `canBecomeMain` stays false: this is an accessory panel, not the app's main
/// window, and claiming otherwise confuses window ordering.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
