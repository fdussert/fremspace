// Draws the app icon (a display holding three slots) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from the repository root; needs iconutil)
import AppKit

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // The macOS icon grid: the shape takes 824 of 1024 points, corner radius 185.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(starting: NSColor(red: 0.20, green: 0.24, blue: 0.36, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1))!.draw(in: shape, angle: -90)
    // Three slots: a tall one and two stacked, with the gap Fremspace leaves between windows.
    let pad = body.width * 0.17, gap = body.width * 0.045
    let area = body.insetBy(dx: pad, dy: pad * 1.15)
    let leftWidth = (area.width - gap) * 0.58
    let radius = body.width * 0.045
    func slot(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    slot(NSRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height),
         NSColor(red: 0.36, green: 0.62, blue: 1.0, alpha: 1))
    let rightX = area.minX + leftWidth + gap, rightWidth = area.width - leftWidth - gap
    let half = (area.height - gap) / 2
    slot(NSRect(x: rightX, y: area.minY + half + gap, width: rightWidth, height: half), NSColor(white: 1, alpha: 0.92))
    slot(NSRect(x: rightX, y: area.minY, width: rightWidth, height: half), NSColor(white: 1, alpha: 0.45))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Fremspace-\(getpid()).iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! draw(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! draw(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! tool.run()
tool.waitUntilExit()
try? fm.removeItem(at: iconset)
print(tool.terminationStatus == 0 ? "Resources/AppIcon.icns written" : "iconutil failed")
