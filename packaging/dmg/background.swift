import AppKit

// Draws the picture behind the icons of the disk image's window, at 1x and 2x, as PNG files:
//   swift packaging/dmg/background.swift <folder>
// `scripts/make-dmg-background.sh` joins the two into packaging/dmg/background.tiff, which is the
// file the repository keeps and `scripts/make-dmg.sh` copies. The numbers below are shared with
// that script: the window is 640 x 400 points, the app's icon is centred on (170, 180) and the
// Applications folder on (470, 180), measured from the top left as the Finder does.
let size = CGSize(width: 640, height: 400)
let app = CGPoint(x: 170, y: 180), applications = CGPoint(x: 470, y: 180)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(scale: CGFloat, to url: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, in points, like the Finder's positions.
    context.translateBy(x: 0, y: size.height * scale)
    context.scaleBy(x: scale, y: -scale)

    // The night blue of the site, a little lighter at the top.
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x111c4a), color(0x0a1030), color(0x07080c)] as CFArray,
                              locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // Light behind each icon: strong where the app is, faint where it goes.
    func glow(_ centre: CGPoint, _ hex: UInt32, _ alpha: CGFloat, radius: CGFloat) {
        let light = CGGradient(colorsSpace: space, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(light, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
    }
    glow(CGPoint(x: app.x, y: app.y + 6), 0x2150ea, 0.55, radius: 230)
    glow(CGPoint(x: applications.x, y: applications.y + 6), 0x4f9bff, 0.16, radius: 200)

    // A slot for each icon, as Fremspace draws them: the app goes from its slot to the one of
    // Applications, which is still empty.
    func slotPath(around centre: CGPoint) -> CGPath {
        CGPath(roundedRect: CGRect(x: centre.x - 98, y: centre.y - 94, width: 196, height: 212),
               cornerWidth: 20, cornerHeight: 20, transform: nil)
    }
    func slot(around centre: CGPoint, filled: Bool) {
        let path = slotPath(around: centre)
        context.saveGState()
        context.addPath(path)
        context.clip()
        let fill = CGGradient(colorsSpace: space,
                              colors: [color(0x8fbeff, filled ? 0.20 : 0.07), color(0x4f9bff, filled ? 0.05 : 0.02)] as CFArray,
                              locations: [0, 1])!
        context.drawLinearGradient(fill, start: CGPoint(x: 0, y: centre.y - 94), end: CGPoint(x: 0, y: centre.y + 118), options: [])
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(color(filled ? 0x8fbeff : 0x4f9bff, filled ? 0.75 : 0.45))
        context.setLineWidth(filled ? 1.5 : 1.25)
        if !filled { context.setLineDash(phase: 0, lengths: [7, 6]) }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }
    slot(around: app, filled: true)
    slot(around: applications, filled: false)

    // Between the two: chevrons that brighten on the way, the nearest thing to movement a still
    // picture has (the Finder shows no animation behind a window's icons).
    let y = app.y + 12
    let first = app.x + 98 + 26, last = applications.x - 98 - 26
    let count = 4
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for step in 0..<count {
        let t = CGFloat(step) / CGFloat(count - 1)
        let x = first + (last - first - 10) * t
        context.setStrokeColor(color(0x8fbeff, 0.22 + 0.73 * t))
        context.setLineWidth(2.5 + 1.0 * t)
        context.move(to: CGPoint(x: x, y: y - 11))
        context.addLine(to: CGPoint(x: x + 10, y: y))
        context.addLine(to: CGPoint(x: x, y: y + 11))
        context.strokePath()
    }

    // One line of words, under the icons' names.
    let text = NSAttributedString(string: "Drag Fremspace to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: NSColor(cgColor: color(0xeef1f7, 0.92))!,
        .kern: 0.2,
    ])
    let line = CTLineCreateWithAttributedString(text)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.saveGState()
    // Text is drawn the right way up: back to a bottom-left origin for this line.
    context.translateBy(x: (size.width - CGFloat(width)) / 2, y: 356)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()

    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    image.size = size
    try! image.representation(using: .png, properties: [:])!.write(to: url)
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
draw(scale: 1, to: folder.appendingPathComponent("background.png"))
draw(scale: 2, to: folder.appendingPathComponent("background@2x.png"))
