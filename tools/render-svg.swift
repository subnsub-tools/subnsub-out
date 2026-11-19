// Renders an SVG to a PNG of the given size in pixels, through AppKit.
//   swift tools/render-svg.swift Resources/dmg/background.svg Resources/dmg/background.png 640 430
//   swift tools/render-svg.swift Resources/dmg/background.svg Resources/dmg/background@2x.png 1280 860
import AppKit

let a = CommandLine.arguments
guard a.count == 5, let image = NSImage(contentsOf: URL(fileURLWithPath: a[1])), let w = Int(a[3]), let h = Int(a[4]) else {
    FileHandle.standardError.write(Data("usage: render-svg.swift <svg> <png> <width> <height>\n".utf8)); exit(2)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
