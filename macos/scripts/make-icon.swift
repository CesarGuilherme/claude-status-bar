// Draws the app icon into an .iconset folder: a warm squircle with the
// Claude mark and the two 5h/7d meters the menu bar shows.
// Usage: swift scripts/make-icon.swift <out.iconset> <claude.svg>
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let out = URL(fileURLWithPath: arguments.first ?? "AppIcon.iconset")
let mark = arguments.count > 1 ? NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) : nil
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ side: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let inset = rect.insetBy(dx: side * 0.1, dy: side * 0.1)
        let shape = NSBezierPath(roundedRect: inset, xRadius: side * 0.2, yRadius: side * 0.2)
        NSGradient(colors: [
            NSColor(red: 0.98, green: 0.66, blue: 0.36, alpha: 1),
            NSColor(red: 0.80, green: 0.33, blue: 0.16, alpha: 1),
        ])?.draw(in: shape, angle: -90)

        if let mark {
            let size = side * 0.42
            // The SVG is one color: tint it white in its own image, where
            // sourceAtop only touches the mark, then place it on the orange.
            let white = NSImage(size: NSSize(width: size, height: size), flipped: false) { box in
                mark.draw(in: box)
                NSColor.white.set()
                box.fill(using: .sourceAtop)
                return true
            }
            white.draw(in: NSRect(x: rect.midX - size / 2, y: inset.minY + inset.height * 0.56 - size / 2, width: size, height: size))
        }

        let barWidth = inset.width * 0.56
        let barHeight = side * 0.045
        let left = rect.midX - barWidth / 2
        for (row, fill) in [(0, 0.72), (1, 0.38)] {
            let y = inset.minY + inset.height * 0.2 - CGFloat(row) * barHeight * 1.9
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: y, width: barWidth, height: barHeight),
                         xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: y, width: barWidth * fill, height: barHeight),
                         xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }
        return true
    }
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let image = draw(pixels)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: out.appendingPathComponent(name))
    }
}
