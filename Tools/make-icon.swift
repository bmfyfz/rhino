// Turns square artwork into Rhino's app icon set.
//
// A Mac icon is not the artwork itself: it sits on a rounded plate that
// covers 824 of the canvas's 1024 points, with a soft shadow beneath. This
// cuts the artwork to that plate, adds the shadow, and writes every size the
// asset catalog needs.
//
//   swift Tools/make-icon.swift artwork.png
//
// The artwork should be square, at least 1024 pixels, with its background
// reaching all four edges.
import AppKit

guard CommandLine.arguments.count > 1, let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: swift Tools/make-icon.swift <square artwork.png>\n".utf8))
    exit(1)
}

let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconSet = tools.deletingLastPathComponent().appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func render(_ pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    // Everything is laid out on a 1024-point canvas and scaled to the size asked for.
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * CGFloat(pixels) / 1024), blur: 28 * CGFloat(pixels) / 1024, color: CGColor(gray: 0, alpha: 0.32))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.draw(source, in: plate)
    // A hairline of light along the top edge, as glass catches it.
    context.addPath(shape)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
    context.setLineWidth(6)
    context.strokePath()
    context.restoreGState()

    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-\(points * scale).png"
        try render(points * scale).write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: iconSet.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon sizes to \(iconSet.path)")
