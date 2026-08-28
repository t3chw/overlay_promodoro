import SwiftUI
import AppKit

// Renders assets/Pomodoro.icns from the dial design. The .icns is committed so
// build.sh (and CI) never need to run this — regenerate only if the mark changes.

struct AppIcon: View {
    // macOS icons sit on a squircle inset from the 1024pt canvas, not edge to edge.
    private let canvas: CGFloat = 1024
    private let plate:  CGFloat = 824

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x33343A), Color(hex: 0x141519)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 3)
                )
                .frame(width: plate, height: plate)
                .shadow(color: .black.opacity(0.45), radius: 26, y: 14)

            let ring: CGFloat = 470
            let stroke: CGFloat = 78
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: stroke)
                Circle()
                    // Same direction the app drains: gap opens clockwise from 12.
                    .trim(from: 0.26, to: 1)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Color(hex: 0xFF6B5B),
                                                        Color(hex: 0xFFA45B),
                                                        Color(hex: 0xFF6B5B)]),
                            center: .center,
                            startAngle: .degrees(-90), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Color(hex: 0xFF6B5B).opacity(0.45), radius: 26)
            }
            .frame(width: ring, height: ring)
        }
        .frame(width: canvas, height: canvas)
    }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

let png: Data? = MainActor.assumeIsolated {
    let r = ImageRenderer(content: AppIcon())
    r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}
guard let png else { print("render failed"); exit(1) }
try png.write(to: URL(fileURLWithPath: "build/icon-1024.png"))
print("wrote build/icon-1024.png")
