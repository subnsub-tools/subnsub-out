import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import IOSurface
import QingyanCore

/// A standard session's picture (ScreenWire's picture frames): the other Mac's display as pixels, kept
/// whole here and changed a rectangle at a time as that Mac sends what changed. Each time an update
/// is whole the picture goes to the window's display layer as a sample of its own, so the window
/// shows it as it shows a High Performance session's video and needs to know nothing of the kind.
/// Nothing is decoded and nothing is drawn while that Mac's display does not change (user
/// 2026-11-23: the system's own standard mode keeps this Mac cool, and the video did not).
///
/// A piece comes as exact pixels, or as a JPEG of them where that Mac's display is changing (an
/// adaptive session, user 2026-11-24: without it the picture lags too far behind to work with);
/// the helper sends the same place exact once it rests, so a JPEG's pixels are only ever drawn over.
///
/// A sample's pixels are a buffer from a pool. A buffer that comes round again still holds the
/// picture it last carried, so only what changed since then is copied into it: the canvas remembers
/// what each of its last samples changed, and each buffer's surface which sample it carried. A
/// surface not known, or written by anyone else since, is copied whole.
final class ScreenCanvas {
    private(set) var width = 0
    private(set) var height = 0
    /// The picture: BGRA rows, nothing transparent.
    private var pixels: UnsafeMutablePointer<UInt8>?
    private var scratch: UnsafeMutablePointer<UInt8>?
    private var scratchCount = 0
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?

    private struct Box {
        var x0: Int, y0: Int, x1: Int, y1: Int
        func union(_ other: Box) -> Box { Box(x0: min(x0, other.x0), y0: min(y0, other.y0), x1: max(x1, other.x1), y1: max(y1, other.y1)) }
    }
    /// What changed since the last sample, and what each of the last samples changed (the newest last).
    private var changed: Box?
    private var history: [Box?] = []
    private var samples = 0
    /// The sample each surface last carried, and the surface's seed once it had.
    private var carried: [IOSurfaceID: (sample: Int, seed: UInt32)] = [:]
    private static let remembered = 12

    deinit {
        pixels?.deallocate()
        scratch?.deallocate()
    }

    /// The picture's size, in pixels: what it showed stays where it was, and the rest is black. False
    /// for a size no display has.
    func resize(width w: Int, height h: Int) -> Bool {
        guard w > 0, h > 0, w <= ScreenWire.pictureSideLimit, h <= ScreenWire.pictureSideLimit, w * h <= ScreenWire.pictureAreaLimit else { return false }
        if w == width, h == height, pixels != nil { return true }
        let next = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        var black: UInt32 = 0xFF00_0000
        memset_pattern4(next, &black, w * h * 4)
        if let pixels {
            let columns = min(w, width) * 4
            for row in 0..<min(h, height) { (next + row * w * 4).update(from: pixels + row * width * 4, count: columns) }
            pixels.deallocate()
        }
        pixels = next
        width = w
        height = h
        pool = nil
        format = nil
        carried = [:]
        history = []
        changed = Box(x0: 0, y0: 0, x1: w, y1: h)
        return true
    }

    /// One piece into the picture; false when it does not lie in it or its pixels are not what it says.
    func draw(_ piece: ScreenWire.PicturePiece) -> Bool {
        guard let pixels, piece.width > 0, piece.height > 0, piece.x + piece.width <= width, piece.y + piece.height <= height else { return false }
        let count = piece.width * piece.height * 4
        guard count <= ScreenWire.pieceLimit else { return false }
        let box = Box(x0: piece.x, y0: piece.y, x1: piece.x + piece.width, y1: piece.y + piece.height)
        // Into room for one byte more than the piece's pixels: exactly that many have to come.
        if scratchCount < count + 1 {
            scratch?.deallocate()
            scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: count + 1)
            scratchCount = count + 1
        }
        guard let scratch else { return false }
        if piece.jpeg {
            guard Self.decode(piece.deflated, into: scratch, width: piece.width, height: piece.height) else { return false }
        } else {
            guard ScreenWire.inflate(piece.deflated, into: scratch, capacity: count + 1) == count else { return false }
        }
        for row in 0..<piece.height {
            (pixels + ((piece.y + row) * width + piece.x) * 4).update(from: scratch + row * piece.width * 4, count: piece.width * 4)
        }
        changed = changed.map { $0.union(box) } ?? box
        return true
    }

    /// A JPEG's pixels into `room` as BGRA rows, nothing transparent; false when it is not a picture of
    /// this size. Drawn in the picture's own color space, so its values come as they were sent.
    private static func decode(_ jpeg: Data, into room: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> Bool {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height,
              let context = CGContext(data: room, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The byte no color is in is not left to the drawing.
        var at = room + 3
        for _ in 0..<(width * height) {
            at.pointee = 0xFF
            at += 4
        }
        return true
    }

    /// The picture as it is now, as a sample the display layer shows at once.
    func sample() -> CMSampleBuffer? {
        guard let pixels, width > 0, height > 0 else { return nil }
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
            pool = made
        }
        guard let pool else { return nil }
        var taken: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &taken) == kCVReturnSuccess, let buffer = taken else { return nil }
        samples += 1
        history.append(changed)
        changed = nil
        if history.count > Self.remembered { history.removeFirst(history.count - Self.remembered) }
        // What this buffer does not show yet: everything, unless its surface carried a sample
        // recent enough that what changed since is remembered.
        var stale: Box? = Box(x0: 0, y0: 0, x1: width, y1: height)
        let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        if let surface, let last = carried[IOSurfaceGetID(surface)], last.seed == IOSurfaceGetSeed(surface), samples - last.sample <= history.count {
            stale = nil
            for entry in history.suffix(samples - last.sample) {
                if let entry { stale = stale.map { $0.union(entry) } ?? entry }
            }
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        if let stale {
            // A buffer that cannot be written is not shown, and its surface is not taken to carry this sample.
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self),
                  CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                // What this sample changed is still to be shown.
                changed = history.removeLast()
                samples -= 1
                return nil
            }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let columns = (stale.x1 - stale.x0) * 4
            for row in stale.y0..<stale.y1 {
                (base + row * stride + stale.x0 * 4).update(from: pixels + (row * width + stale.x0) * 4, count: columns)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if let surface {
            carried[IOSurfaceGetID(surface)] = (samples, IOSurfaceGetSeed(surface))
            if carried.count > 64 {
                let now = samples
                carried = carried.filter { now - $0.value.sample <= Self.remembered }
            }
        }
        if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) }) ?? true {
            var made: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &made)
            format = made
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Of a few thousand pixels across the picture, how many in a thousand are not black.
    func lit() -> Int {
        guard let pixels, width > 0, height > 0 else { return 0 }
        let total = width * height, step = max(1, total / 4096)
        var seen = 0, lit = 0, at = 0
        while at < total {
            let pixel = pixels + at * 4
            seen += 1
            if pixel[0] > 16 || pixel[1] > 16 || pixel[2] > 16 { lit += 1 }
            at += step
        }
        return lit * 1000 / max(seen, 1)
    }

    /// The picture as an image (a screenshot).
    func image() -> CGImage? {
        guard let pixels, width > 0, height > 0,
              let provider = CGDataProvider(data: Data(bytes: pixels, count: width * height * 4) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
