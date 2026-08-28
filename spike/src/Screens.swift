import AppKit
_ = NSApplication.shared
for (i, s) in NSScreen.screens.enumerated() {
    let m = (s == NSScreen.main) ? "  <== NSScreen.main" : ""
    print("display \(i): frame=\(s.frame.width)x\(s.frame.height) @ \(s.frame.origin.x),\(s.frame.origin.y)\(m)")
}
