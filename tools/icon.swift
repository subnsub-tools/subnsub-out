// Makes AppIcon.icns from AppIcon.svg: every size macOS asks for, drawn with the soft shadow the
// macOS icon grid leaves room for (the 824 body sits in a 1024 canvas).
//   swift tools/icon.swift Resources/AppIcon.svg Resources/AppIcon.icns
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("usage: icon.swift <AppIcon.svg> <AppIcon.icns>\n".utf8)); exit(2)
}
let files = FileManager.default
let set = files.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try files.createDirectory(at: set, withIntermediateDirectories: true)
defer { try? files.removeItem(at: set) }

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let k = CGFloat(pixels) / 1024
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.shadowBlurRadius = 20 * k
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.set()
    art.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points * scale).write(to: set.appendingPathComponent(name))
    }
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", set.path, "-o", args[2]]
try tool.run(); tool.waitUntilExit()
exit(tool.terminationStatus)
