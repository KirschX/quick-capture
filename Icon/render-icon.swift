// Draws the app icon's layers into ShowAndTell/AppIcon.icon/Assets and the dev build's ShowAndTell/AppIconDev.icon/Assets.
// Run from the repo root: swiftc -parse-as-library -default-isolation MainActor -o /tmp/render-icon Icon/render-icon.swift && /tmp/render-icon
// The icon's background colour is the `fill` in each icon's icon.json (orange for the dev build).
import AppKit
import SwiftUI

extension Color {
    init(_ hex: UInt32, _ opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

let markerRed = LinearGradient(colors: [Color(0xFF6E6E), Color(0xE0353B)], startPoint: .top, endPoint: .bottom)

/// The numbered badge, as drawn on markers in the app.
struct Badge: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(markerRed)
            Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)).padding(size * 0.08)
            Circle().strokeBorder(.white, lineWidth: size * 0.085)
            Text("1").font(.system(size: size * 0.52, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(0xB01E24, 0.45), radius: size * 0.12, y: size * 0.06)
    }
}

/// A dark Mac window with a red marker box on it. Layout is in points of the 824pt icon body.
struct MarkedWindow: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 46, style: .continuous).fill(Color(0x2A2D35))
            RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 3)
            HStack(spacing: 16) {
                Circle().fill(Color(0xFF5F57)); Circle().fill(Color(0xFEBC2E)); Circle().fill(Color(0x28C840))
            }
            .frame(width: 104, height: 28).offset(x: 40, y: 36)
            VStack(alignment: .leading, spacing: 26) {
                ForEach([150.0, 110, 140], id: \.self) { width in
                    Capsule().fill(Color(0x434754)).frame(width: width, height: 34)
                }
            }
            .offset(x: 44, y: 120)
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(0xE5484D, 0.14))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(markerRed, lineWidth: 20))
                .frame(width: 250, height: 190).offset(x: 260, y: 130)
            Badge(size: 130).offset(x: 195, y: 65)
        }
        .frame(width: 580, height: 420)
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        .offset(x: 20, y: 30)
    }
}

/// The faint card behind the window.
struct BackCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 46, style: .continuous).fill(.white.opacity(0.09))
            .frame(width: 560, height: 400).rotationEffect(.degrees(-9)).offset(x: -40, y: -40)
    }
}

/// Renders a layer drawn on the 824pt icon body to a 1024px canvas, which Icon Composer fills edge to edge.
func render(_ layer: some View, to name: String) throws {
    let renderer = ImageRenderer(content: layer.frame(width: 824, height: 824))
    renderer.scale = 1024 / 824
    let png = NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
    for icon in ["AppIcon", "AppIconDev"] {
        try png.write(to: URL(filePath: "ShowAndTell/\(icon).icon/Assets/\(name).png"))
    }
}

@main struct RenderIcon {
    static func main() throws {
        try render(BackCard(), to: "back")
        try render(MarkedWindow(), to: "window")
    }
}
