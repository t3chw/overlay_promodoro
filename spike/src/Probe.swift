import AppKit

// Dumps the window server's on-screen list, front-to-back. This is ground
// truth for "is it on top" -- no screen recording permission needed for
// layer/owner/bounds.
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("window list unavailable"); exit(1)
}
print(String(format: "%-4s %-26s %-8s %s", ("z" as NSString).utf8String!,
             ("owner" as NSString).utf8String!,
             ("layer" as NSString).utf8String!,
             ("bounds" as NSString).utf8String!))
print(String(repeating: "-", count: 78))
for (i, w) in raw.enumerated() {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    var b = "?"
    if let d = w[kCGWindowBounds as String] as? [String: Any],
       let x = d["X"] as? Double, let y = d["Y"] as? Double,
       let wd = d["Width"] as? Double, let h = d["Height"] as? Double {
        b = String(format: "%.0fx%.0f @ %.0f,%.0f", wd, h, x, y)
    }
    let mark = owner.contains("FloatingSpike") ? "  <== THE PILL"
             : owner.contains("FullScreenTester") ? "  <== full-screen app" : ""
    print("\(i)\t\(owner.padding(toLength: min(24, max(owner.count, 24)), withPad: " ", startingAt: 0))\tlayer=\(layer)\t\(b)\(mark)")
}
