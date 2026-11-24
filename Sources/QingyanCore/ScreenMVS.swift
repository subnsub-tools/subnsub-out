//
//  ScreenMVS.swift
//
//  Decoder for the "Multi-Variant Scaled" framebuffer encoding of Apple
//  Screen Sharing (RFB encoding 0x3f3), the one a Mac sends in adaptive
//  quality.
//
//  The decoder follows the behaviour of Apple's own viewer as established by
//  a reference decoder that was compared with it byte for byte. That includes
//  what the viewer does with bodies that break the format: which tiles are
//  drawn before it gives up, and whether it gives up at all. Where the viewer
//  would read memory it never set (bytes past the end of a body, pixels past
//  the end of the picture), this decoder reads zeros, as the reference does.
//
//  A picture is made of tiles of 8 by 8 pixels. A rectangle's body is one of:
//
//    quantisation tables   two tables of 64 bytes for the inverse DCT
//    full update           every tile of the rectangle, from two bit streams:
//                          a command for each run of tiles, and their data
//    partial update        a second pass over tiles of earlier full updates
//                          that adds detail, repeats copies, or draws a tile
//                          again from the tile cache
//
//  State kept between rectangles: the quantisation tables, a record for every
//  tile of the picture (what the last full update sent for it), and the tile
//  cache (the coefficients of every tile a partial update refined).
//

import Foundation

/// Why a rectangle was refused.
public enum ScreenMVSError: Error, Equatable {
    /// The body breaks the format. Apple's viewer reports a protocol error and closes the session.
    case malformedBody
    /// A partial update arrived before any full update or quantisation tables.
    case partialUpdateBeforeFullUpdate
    /// Quantisation tables whose body is not 129 bytes long.
    case quantisationTablesLength

    /// The status Apple's viewer returns for the same body.
    public var viewerStatus: Int {
        switch self {
        case .malformedBody: return -201
        case .partialUpdateBeforeFullUpdate: return -300
        case .quantisationTablesLength: return -2
        }
    }
}

/// Decodes the rectangles of one session into a picture the caller owns.
///
/// Not safe to use from several threads at once: call it from one queue.
public final class ScreenMVS {

    /// A part of the picture, in pixels.
    public typealias Rectangle = (x: Int, y: Int, width: Int, height: Int)

    /// The longest body Apple's viewer accepts. The caller reads the length and should end the session
    /// for a longer one.
    public static let maximumBodyLength = 100_000_000

    /// Bytes kept for every tile of the picture.
    static let tileRecordSize = 0x54
    /// Bytes of one tile cache entry: 64 luma, 15 red-difference and 20 blue-difference coefficients.
    static let tileCacheEntrySize = 0x63
    /// Entries in the tile cache.
    static let tileCacheEntryCount = 65000

    // MARK: Layout of a tile record

    /// How many luma coefficients the full update sent in full precision.
    private static let recordLumaCount = 0x00
    /// The 64 luma coefficients of the full update, low bytes, in zig-zag order.
    private static let recordLuma = 0x01
    /// 1 when the tile was sent as a DCT tile, checked before a partial update refines it.
    private static let recordCrMarker = 0x41
    /// The red-difference DC coefficient of the full update.
    private static let recordCrDC = 0x42
    /// 1 when the tile was sent as a DCT tile.
    private static let recordCbMarker = 0x43
    /// The blue-difference DC coefficient of the full update.
    private static let recordCbDC = 0x44
    /// Which full update touched the tile last.
    private static let recordSerial = 0x48
    /// The tile this one was copied from, or -1.
    private static let recordSource = 0x4c
    /// Where in the picture that tile's pixels start, in bytes.
    private static let recordSourceOffset = 0x50

    // MARK: The picture

    /// The picture's width in pixels, 0 until `resize` is called.
    private(set) var width = 0
    /// The picture's height in pixels.
    private(set) var height = 0
    /// Bytes from one row of the picture to the next.
    private(set) var bytesPerRow = 0
    /// Bytes of the whole picture.
    private var pictureLength = 0
    /// Tiles in one row of the picture.
    private var tilesPerRow = 0

    // MARK: State kept between rectangles
    //
    // Readable inside the module, and the tile cache counters writable, so that the test tool can
    // compare the state with the reference decoder's and start in the middle of a session.
    // Nothing else should write them.

    /// Tiles in the picture.
    private(set) var tileCount = 0
    /// One record for every tile of the picture, row by row.
    private(set) var tileRecords: UnsafeMutablePointer<UInt8>?
    /// The tile cache, allocated when the first full update or quantisation tables arrive.
    private(set) var tileCache: UnsafeMutablePointer<UInt8>?
    /// True once a full update or quantisation tables have been received.
    private(set) var isSetUp = false
    /// Counts full updates.
    private(set) var updateSerial: UInt32 = 0
    /// The tile cache entry drawn last. "The next entry" in a body means this plus one.
    var tileCacheLastDrawn: UInt16 = 0
    /// The tile cache entry written last. Entries are written at 1, 2, ... 64999, then 1 again.
    var tileCacheLastWritten: UInt16 = 0
    /// How many entries were ever written. An entry above this number is not drawn.
    var tileCacheWrittenCount: UInt32 = 0
    /// The luma quantisation table, in row order.
    let lumaQuantisation: UnsafeMutablePointer<Int32>
    /// The chroma quantisation table, in row order.
    let chromaQuantisation: UnsafeMutablePointer<Int32>

    // MARK: Tables

    /// Maps a 10-bit inverse DCT result to a sample: adds 128 and limits to 0...255.
    private let rangeLimit: UnsafeMutablePointer<UInt8>
    /// Zig-zag position to position in row order: 64 entries, then 16 more of 63 for runs that overshoot.
    private let zigzag: UnsafeMutablePointer<UInt8>
    /// Huffman: code length for the next 8 bits, or 0 when the code is longer.
    private let huffmanLookLength: UnsafeMutablePointer<UInt8>
    /// Huffman: symbol for the next 8 bits.
    private let huffmanLookSymbol: UnsafeMutablePointer<UInt8>
    /// Huffman: largest code of each length, -1 where there is none; entry 17 ends every search.
    private let huffmanMaxCode: UnsafeMutablePointer<Int32>
    /// Huffman: what to add to a code of each length to find its symbol.
    private let huffmanValueOffset: UnsafeMutablePointer<Int32>
    /// Huffman: the symbols, shortest code first.
    private let huffmanSymbols: UnsafeMutablePointer<UInt8>

    // MARK: Working memory, allocated once

    /// Coefficients of the tile being drawn: luma, blue-difference, red-difference, 64 each, in row order.
    private let coefficients: UnsafeMutablePointer<Int16>
    /// Luma coefficients of the DCT tile being read in a full update, and of the one before it.
    private let lumaPair: UnsafeMutablePointer<Int16>
    /// Low bytes of the luma coefficients being read, in zig-zag order, for the tile record.
    private let lumaBytes: UnsafeMutablePointer<UInt8>
    /// The inverse DCT's intermediate values, column after column.
    private let workspace: UnsafeMutablePointer<Int32>
    /// Samples of the three planes after the inverse DCT: for each plane eight vectors, one for each
    /// column of the tile, holding that column's samples from the top row down.
    private let samples: UnsafeMutablePointer<SIMD8<Int32>>
    /// The pixels of the tile being drawn, column after column.
    private let pixelColumns: UnsafeMutablePointer<SIMD8<UInt32>>
    /// The pixels of a DCT tile that was clipped, kept for a tile that repeats it.
    private let blockTile: UnsafeMutablePointer<UInt8>
    /// A tile that sticks out of its rectangle is drawn here, 32 bytes a row, and its visible part copied.
    private let edgeTile: UnsafeMutablePointer<UInt8>
    /// A tile cache entry under construction.
    private let entryScratch: UnsafeMutablePointer<UInt8>

    /// The fourth byte of every pixel written, as it sits in a 32-bit pixel.
    private static let opaque: UInt32 = 0xff00_0000
    /// The fourth bytes of two pixels loaded from memory as one 64-bit value.
    private static let opaquePair = UInt64(littleEndian: 0xff00_0000_ff00_0000)

    // MARK: Setting up

    public init() {
        lumaQuantisation = .allocate(capacity: 64)
        chromaQuantisation = .allocate(capacity: 64)
        rangeLimit = .allocate(capacity: 1024)
        zigzag = .allocate(capacity: 80)
        huffmanLookLength = .allocate(capacity: 256)
        huffmanLookSymbol = .allocate(capacity: 256)
        huffmanMaxCode = .allocate(capacity: 18)
        huffmanValueOffset = .allocate(capacity: 17)
        huffmanSymbols = .allocate(capacity: 256)
        coefficients = .allocate(capacity: 192)
        lumaPair = .allocate(capacity: 128)
        lumaBytes = .allocate(capacity: 64)
        workspace = .allocate(capacity: 64)
        samples = .allocate(capacity: 24)
        pixelColumns = .allocate(capacity: 8)
        blockTile = .allocate(capacity: 256)
        edgeTile = .allocate(capacity: 256)
        entryScratch = .allocate(capacity: ScreenMVS.tileCacheEntrySize)

        coefficients.initialize(repeating: 0, count: 192)
        lumaPair.initialize(repeating: 0, count: 128)
        lumaBytes.initialize(repeating: 0, count: 64)
        workspace.initialize(repeating: 0, count: 64)
        samples.initialize(repeating: SIMD8<Int32>(repeating: 0), count: 24)
        pixelColumns.initialize(repeating: SIMD8<UInt32>(repeating: 0), count: 8)
        blockTile.initialize(repeating: 0, count: 256)
        edgeTile.initialize(repeating: 0, count: 256)
        entryScratch.initialize(repeating: 0, count: ScreenMVS.tileCacheEntrySize)

        for i in 0..<64 {
            lumaQuantisation[i] = Int32(ScreenMVS.defaultLumaQuantisation[i])
            chromaQuantisation[i] = Int32(ScreenMVS.defaultChromaQuantisation[i])
            zigzag[i] = ScreenMVS.zigzagOrder[i]
        }
        for i in 64..<80 {
            zigzag[i] = 63
        }
        for i in 0..<1024 {
            let sample: Int
            if i < 128 {
                sample = i + 128
            } else if i < 512 {
                sample = 255
            } else if i < 896 {
                sample = 0
            } else {
                sample = i - 896
            }
            rangeLimit[i] = UInt8(truncatingIfNeeded: sample)
        }
        ScreenMVS.buildHuffmanTables(lookLength: huffmanLookLength, lookSymbol: huffmanLookSymbol,
                                     maxCode: huffmanMaxCode, valueOffset: huffmanValueOffset,
                                     symbols: huffmanSymbols)
    }

    deinit {
        free(tileRecords)
        free(tileCache)
        lumaQuantisation.deallocate()
        chromaQuantisation.deallocate()
        rangeLimit.deallocate()
        zigzag.deallocate()
        huffmanLookLength.deallocate()
        huffmanLookSymbol.deallocate()
        huffmanMaxCode.deallocate()
        huffmanValueOffset.deallocate()
        huffmanSymbols.deallocate()
        coefficients.deallocate()
        lumaPair.deallocate()
        lumaBytes.deallocate()
        workspace.deallocate()
        samples.deallocate()
        pixelColumns.deallocate()
        blockTile.deallocate()
        edgeTile.deallocate()
        entryScratch.deallocate()
    }

    /// The picture's size, in pixels: call it before the first rectangle and whenever the picture's size changes.
    ///
    /// What is known about each tile is dropped, as Apple's viewer does when it gets a new bitmap.
    /// The quantisation tables and the tile cache are kept: the server does not send them again.
    ///
    /// - Parameter bytesPerRow: bytes from one row of the caller's picture to the next, `width * 4` when left out.
    ///   It must be a multiple of 4 and at least `width * 4`.
    /// - Returns: false when the size cannot be used: a side above 65535, a bad `bytesPerRow`, a picture
    ///   of 2 GB or more, or no memory for the tile records. The picture is then empty and nothing is drawn.
    @discardableResult
    public func resize(width: Int, height: Int, bytesPerRow: Int? = nil) -> Bool {
        free(tileRecords)
        tileRecords = nil
        tileCount = 0
        self.width = 0
        self.height = 0
        self.bytesPerRow = 0
        pictureLength = 0
        tilesPerRow = 0

        guard width >= 0, height >= 0, width <= 0xffff, height <= 0xffff else {
            return false
        }
        let rowBytes = bytesPerRow ?? width * 4
        guard rowBytes >= width * 4, rowBytes % 4 == 0, rowBytes <= Int(Int32.max) else {
            return false
        }
        let length = rowBytes * height
        guard length <= Int(Int32.max) else {
            return false
        }
        let tiles = ((width + 7) >> 3) * ((height + 7) >> 3)
        if tiles > 0 {
            guard let memory = calloc(tiles, ScreenMVS.tileRecordSize) else {
                return false
            }
            tileRecords = memory.assumingMemoryBound(to: UInt8.self)
        }
        tileCount = tiles
        self.width = width
        self.height = height
        self.bytesPerRow = rowBytes
        pictureLength = length
        tilesPerRow = (width + 7) >> 3
        return true
    }

    /// Whether a rectangle lies inside the picture. Apple's viewer closes the session for a 0x3f3 rectangle
    /// that does not, before it reads the body; `decode` itself only skips such a rectangle.
    public func contains(x: Int, y: Int, width w: Int, height h: Int) -> Bool {
        guard x >= 0, y >= 0, w >= 0, h >= 0, x <= 0xffff, y <= 0xffff, w <= 0xffff, h <= 0xffff else {
            return false
        }
        return width > x && width >= w && x + w <= width && height > y && height >= h && y + h <= height
    }

    // MARK: Decoding

    /// One rectangle's body (what follows its four bytes of length) applied to `pixels`.
    ///
    /// `pixels` holds the picture as rows of BGRA pixels, `bytesPerRow` bytes a row and `height` rows,
    /// as given to `resize`. The caller owns it and must keep it between calls: tiles copied from other
    /// tiles are read back from it. Every pixel the decoder writes gets 0xff as its fourth byte.
    ///
    /// - Returns: the part of the picture that may have changed, or nil when nothing was drawn
    ///   (quantisation tables, a rectangle outside the picture, an empty rectangle).
    /// - Throws: `ScreenMVSError` when Apple's viewer returns an error for the body. Tiles decoded before
    ///   the error was found stay drawn, anywhere inside the rectangle.
    public func decode(x: Int, y: Int, width: Int, height: Int, body: UnsafeRawBufferPointer,
                into pixels: UnsafeMutablePointer<UInt8>) throws -> Rectangle? {
        let length = body.count
        // An empty body has no address; the reader never looks at a byte when the length is 0.
        let bytes = body.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(entryScratch)
        let kind: UInt8 = length > 0 ? bytes[0] : 0
        switch kind {
        case 2:
            try readQuantisationTables(bytes, length)
            return nil
        case 1:
            return try decodePartialUpdate(x: x, y: y, w: width, h: height, body: bytes, length: length,
                                           picture: UnsafeMutableRawPointer(pixels))
        default:
            return try decodeFullUpdate(x: x, y: y, w: width, h: height, body: bytes, length: length,
                                        picture: UnsafeMutableRawPointer(pixels))
        }
    }

    /// What the first full update or quantisation tables set up: the tile cache.
    private func setUp() {
        if isSetUp {
            return
        }
        if tileCache == nil {
            tileCache = calloc(ScreenMVS.tileCacheEntryCount, ScreenMVS.tileCacheEntrySize)?
                .assumingMemoryBound(to: UInt8.self)
        }
        isSetUp = true
    }

    /// Quantisation tables: the body is 2, 64 luma bytes, 64 chroma bytes. Entry i scales the coefficient
    /// at position i in row order. The rectangle's place and size mean nothing.
    private func readQuantisationTables(_ body: UnsafePointer<UInt8>, _ length: Int) throws {
        guard length == 0x81 else {
            throw ScreenMVSError.quantisationTablesLength
        }
        setUp()
        for i in 0..<64 {
            lumaQuantisation[i] = Int32(body[1 + i])
            chromaQuantisation[i] = Int32(body[65 + i])
        }
    }

    // MARK: Full update

    /// A full update: 0, the two luma counts, the 24-bit offset of the data stream, the command stream,
    /// the data stream. Every tile of the rectangle is drawn, row by row.
    private func decodeFullUpdate(x: Int, y: Int, w: Int, h: Int, body: UnsafePointer<UInt8>, length: Int,
                                  picture: UnsafeMutableRawPointer) throws -> Rectangle? {
        guard contains(x: x, y: y, width: w, height: h), let records = tileRecords else {
            return nil
        }
        setUp()
        // Anything but 0, 1 and 2 as the first byte is refused here; a missing byte reads as 0.
        if length > 0 && body[0] != 0 {
            throw ScreenMVSError.malformedBody
        }
        let countA = length > 1 ? Int(body[1]) : 0
        let countB = length > 2 ? Int(body[2]) : 0
        let offset = (length > 3 ? Int(body[3]) << 16 : 0) | (length > 4 ? Int(body[4]) << 8 : 0)
            | (length > 5 ? Int(body[5]) : 0)
        if offset > length {
            throw ScreenMVSError.malformedBody
        }
        var commands = BitReader(body, length: length, position: 6)
        var data = BitReader(body, length: length, position: offset)
        // The command stream starts with one bit that means nothing.
        _ = commands.get(1)
        updateSerial = updateSerial &+ 1
        let serial = updateSerial
        // Apple's viewer gives up once a stream is 500 bytes past the end of the body.
        let limit = length &+ 500

        let rowBytes = bytesPerRow
        let tileRowBytes = (rowBytes << 3) & 0xffff_ffff
        let recordSize = ScreenMVS.tileRecordSize

        // Clipped tiles are drawn into `edgeTile`; one that draws nothing leaves what the last one drew.
        for i in 0..<64 {
            UnsafeMutableRawPointer(edgeTile).storeBytes(of: ScreenMVS.opaque.littleEndian,
                                                         toByteOffset: i * 4, as: UInt32.self)
        }
        // The DCT tile before this one, for tiles sent as a difference from it.
        var luma = lumaPair
        var previousLuma = lumaPair + 64
        memset(lumaPair, 0, 128 * MemoryLayout<Int16>.size)
        var previousCb: Int16 = 0
        var previousCr: Int16 = 0
        var previousRecord: UnsafeMutablePointer<UInt8>?
        // Where the pixels of that tile are, for a tile that repeats it.
        var previousBlock = UnsafeRawPointer(blockTile)
        var previousBlockStride = 32
        // Colours a tile can use again without sending them.
        var solid: UInt32 = ScreenMVS.opaque
        var colour0: UInt32 = 0x00ff_ffff | ScreenMVS.opaque
        var colour1: UInt32 = 0x00b5_d5fe | ScreenMVS.opaque

        var xOffset = 0
        var yOffset = 0
        var rowIndex = (y >> 3) * tilesPerRow + (x >> 3)
        var index = rowIndex
        var rowStart = rowBytes * y + 4 * x
        var destination = rowStart
        var lastDestination = destination

        while true {
            if commands.position > limit {
                throw ScreenMVSError.malformedBody
            }
            let command = commands.get(3)
            let repeatCount = commands.repeatCount()
            var run = 0
            var finished = false
            while true {
                guard index >= 0, index < tileCount else {
                    throw ScreenMVSError.malformedBody
                }
                let record = records + index * recordSize
                let rawRecord = UnsafeMutableRawPointer(record)
                rawRecord.storeBytes(of: serial.littleEndian, toByteOffset: ScreenMVS.recordSerial, as: UInt32.self)
                rawRecord.storeBytes(of: Int32(-1).littleEndian, toByteOffset: ScreenMVS.recordSource, as: Int32.self)

                let columns = w &- xOffset
                let rows = h &- yOffset
                let whole = columns > 7 && rows > 7
                let out: UnsafeMutableRawPointer
                let stride: Int
                if whole {
                    guard destination >= 0, destination &+ 7 &* rowBytes &+ 32 <= pictureLength else {
                        throw ScreenMVSError.malformedBody
                    }
                    out = picture + destination
                    stride = rowBytes
                } else {
                    out = UnsafeMutableRawPointer(edgeTile)
                    stride = 32
                }

                switch command {
                case 0:
                    // White.
                    fill(out, stride, 0xffff_ffff)
                case 1:
                    // The same pixels as the tile before this one, wherever that was.
                    rawRecord.storeBytes(of: Int32(truncatingIfNeeded: index &- 1).littleEndian,
                                         toByteOffset: ScreenMVS.recordSource, as: Int32.self)
                    rawRecord.storeBytes(of: UInt32(truncatingIfNeeded: lastDestination).littleEndian,
                                         toByteOffset: ScreenMVS.recordSourceOffset, as: UInt32.self)
                    copyTile(from: lastDestination, in: picture, to: out, stride, skipRowsAbove: false)
                case 2:
                    // The same pixels as the tile above. Rows that would come from above the picture are left alone.
                    let source = destination &- tileRowBytes
                    rawRecord.storeBytes(of: Int32(truncatingIfNeeded: index &- tilesPerRow).littleEndian,
                                         toByteOffset: ScreenMVS.recordSource, as: Int32.self)
                    rawRecord.storeBytes(of: UInt32(truncatingIfNeeded: source).littleEndian,
                                         toByteOffset: ScreenMVS.recordSourceOffset, as: UInt32.self)
                    copyTile(from: source, in: picture, to: out, stride, skipRowsAbove: true)
                case 3:
                    // Black and white, one bit a pixel. A set mask bit means a white row with no bits sent.
                    let mask = data.get(8)
                    for row in 0..<8 {
                        let bits: UInt32 = mask & (0x80 >> UInt32(row)) != 0 ? 0xff : data.get(8)
                        twoColourRow(out + row &* stride, bits, 0xffff_ffff, ScreenMVS.opaque)
                    }
                case 4:
                    // One colour, or two colours and one bit a pixel. Colours are 20 bits: Y, Cb, Cr.
                    let two = data.get(1)
                    let reuse = data.get(1)
                    if two == 0 {
                        if reuse == 0 {
                            solid = readColour(&data)
                        }
                        fill(out, stride, solid)
                    } else {
                        if reuse == 0 {
                            colour0 = readColour(&data)
                            colour1 = readColour(&data)
                        }
                        let mask = data.get(8)
                        for row in 0..<8 {
                            let bits: UInt32 = mask & (0x80 >> UInt32(row)) != 0 ? 0xff : data.get(8)
                            twoColourRow(out + row &* stride, bits, colour0, colour1)
                        }
                    }
                case 5:
                    // DCT: luma coefficients and the two chroma DCs, as differences from the DCT tile before.
                    var cb: Int16 = 0
                    var cr: Int16 = 0
                    let repeated = try readBlock(&data, luma: luma, previousLuma: previousLuma, cb: &cb, cr: &cr,
                                                 previousCb: previousCb, previousCr: previousCr,
                                                 countA: countA, countB: countB,
                                                 record: record, previousRecord: previousRecord)
                    if repeated {
                        // The same coefficients give the same pixels.
                        for row in 0..<8 {
                            memcpy(out + row &* stride, previousBlock + row &* previousBlockStride, 32)
                        }
                    } else {
                        drawBlock(luma: luma, cb: cb, cr: cr, to: out, stride)
                    }
                    if whole {
                        previousBlock = UnsafeRawPointer(out)
                        previousBlockStride = stride
                    } else {
                        // The next clipped tile will draw over `edgeTile`.
                        memcpy(blockTile, edgeTile, 256)
                        previousBlock = UnsafeRawPointer(blockTile)
                        previousBlockStride = 32
                    }
                    swap(&luma, &previousLuma)
                    previousCb = cb
                    previousCr = cr
                    previousRecord = record
                case 6:
                    // A tile cache entry, by number.
                    let high = data.get(8)
                    let entry = Int(high << 8 | data.get(8))
                    _ = drawCacheEntry(entry, to: out, stride)
                default:
                    // The tile cache entry after the one drawn last.
                    _ = drawCacheEntry((Int(tileCacheLastDrawn) &+ 1) & 0xffff, to: out, stride)
                }

                if !whole {
                    try copyEdgeTile(to: destination, in: picture, columns: min(columns, 8), rows: min(rows, 8))
                }

                // On to the next tile.
                let thisDestination = destination
                xOffset = xOffset &+ 8
                if xOffset < w {
                    destination = destination &+ 32
                    index = index &+ 1
                } else {
                    yOffset = yOffset &+ 8
                    if yOffset >= h {
                        finished = true
                        break
                    }
                    xOffset = 0
                    rowIndex = rowIndex &+ tilesPerRow
                    index = rowIndex
                    rowStart = rowStart &+ tileRowBytes
                    destination = rowStart
                }
                lastDestination = thisDestination
                if run == repeatCount {
                    break
                }
                run = run &+ 1
            }
            if finished {
                // Each stream ends with the byte 0x6d, wherever its last bit fell.
                if commands.get(8) != 0x6d || data.get(8) != 0x6d {
                    throw ScreenMVSError.malformedBody
                }
                break
            }
            if data.position > limit {
                throw ScreenMVSError.malformedBody
            }
        }
        return w > 0 && h > 0 ? (x, y, w, h) : nil
    }

    /// A colour of a full update: 8 bits of Y, 6 of Cb, 6 of Cr.
    @inline(__always)
    private func readColour(_ data: inout BitReader) -> UInt32 {
        let y = Int32(truncatingIfNeeded: data.get(8))
        let cb = Int32(truncatingIfNeeded: data.get(6)) << 2
        let cr = Int32(truncatingIfNeeded: data.get(6)) << 2
        return ScreenMVS.limited(y &+ ScreenMVS.blue(cb)) | ScreenMVS.limited(y &+ ScreenMVS.green(cb, cr)) << 8
            | ScreenMVS.limited(y &+ ScreenMVS.red(cr)) << 16 | ScreenMVS.opaque
    }

    /// One DCT tile of a full update, read from the data stream into `luma`, `cb` and `cr`.
    /// On success the tile's record holds what a partial update needs to refine the tile.
    ///
    /// - Returns: true when the tile repeats the DCT tile before it, coefficient for coefficient.
    private func readBlock(_ data: inout BitReader, luma: UnsafeMutablePointer<Int16>,
                           previousLuma: UnsafeMutablePointer<Int16>, cb: inout Int16, cr: inout Int16,
                           previousCb: Int16, previousCr: Int16, countA: Int, countB: Int,
                           record: UnsafeMutablePointer<UInt8>,
                           previousRecord: UnsafeMutablePointer<UInt8>?) throws -> Bool {
        if data.get(1) != 0 {
            // The same coefficients as the DCT tile before. With no such tile in this rectangle the tile
            // is drawn from zeros and its record is left as it was.
            guard let previousRecord = previousRecord else {
                memset(luma, 0, 64 * MemoryLayout<Int16>.size)
                return false
            }
            memcpy(luma, previousLuma, 64 * MemoryLayout<Int16>.size)
            cb = previousCb
            cr = previousCr
            memmove(record, previousRecord, ScreenMVS.tileRecordSize)
            return true
        }
        memset(luma, 0, 64 * MemoryLayout<Int16>.size)
        let flags = data.get(2)
        let count = flags & 1 != 0 ? countB : countA
        if flags & 2 != 0 {
            cb = previousCb
            cr = previousCr
        } else {
            // Chroma DCs are sent halved.
            guard let cbDifference = data.signedValue() else {
                throw ScreenMVSError.malformedBody
            }
            cb = Int16(truncatingIfNeeded: (ScreenMVS.halved(previousCb) &- cbDifference) << 1)
            guard let crDifference = data.signedValue() else {
                throw ScreenMVSError.malformedBody
            }
            cr = Int16(truncatingIfNeeded: (ScreenMVS.halved(previousCr) &- crDifference) << 1)
        }
        guard let lumaDifference = data.signedValue() else {
            throw ScreenMVSError.malformedBody
        }
        let dc = Int16(truncatingIfNeeded: Int(previousLuma[0]) &- lumaDifference)
        luma[0] = dc
        // The low byte of every coefficient, in zig-zag order, for the tile's record.
        let saved = lumaBytes
        memset(saved, 0, 64)
        saved[0] = UInt8(truncatingIfNeeded: dc)

        // Coefficients are sent divided: the first `count` of them by less than the rest.
        let nearShift = count > 14 ? 1 : 3
        let farShift = count > 14 ? 3 : 4
        // Zig-zag positions 1 to 5 use codes with room for larger values than the positions after them.
        var i = 1
        while i < 64 {
            switch data.coefficientCode(early: i < 6, at: i) {
            case .value(let magnitude):
                let value = Int16(truncatingIfNeeded: magnitude << (i < count ? nearShift : farShift))
                luma[Int(zigzag[i])] = value
                saved[i] = UInt8(truncatingIfNeeded: value)
                i = i &+ 1
            case .skip(let positions):
                i = i &+ positions
            case .invalid:
                throw ScreenMVSError.malformedBody
            case .stop:
                // Apple's viewer stops reading the tile here, draws what it has, and does not write
                // the tile's record.
                return false
            }
        }

        record[ScreenMVS.recordLumaCount] = UInt8(truncatingIfNeeded: count)
        memcpy(record + ScreenMVS.recordLuma, saved, 64)
        record[ScreenMVS.recordCrMarker] = 1
        record[ScreenMVS.recordCrDC] = UInt8(truncatingIfNeeded: cr)
        record[ScreenMVS.recordCbMarker] = 1
        record[ScreenMVS.recordCbDC] = UInt8(truncatingIfNeeded: cb)
        return false
    }

    /// Half of a coefficient, rounded towards zero.
    @inline(__always)
    private static func halved(_ value: Int16) -> Int {
        let v = Int(value)
        return v < 0 ? (v &+ 1) >> 1 : v >> 1
    }

    // MARK: Partial update

    /// A partial update: 1, the two limits for chroma coefficients, one bit stream with a 2-bit code for
    /// every tile of the rectangle.
    private func decodePartialUpdate(x: Int, y: Int, w: Int, h: Int, body: UnsafePointer<UInt8>, length: Int,
                                     picture: UnsafeMutableRawPointer) throws -> Rectangle? {
        guard contains(x: x, y: y, width: w, height: h), let records = tileRecords else {
            return nil
        }
        guard isSetUp else {
            throw ScreenMVSError.partialUpdateBeforeFullUpdate
        }
        let limitCr = min(length > 1 ? Int(body[1]) : 0, 64)
        let limitCb = min(length > 2 ? Int(body[2]) : 0, 64)
        var data = BitReader(body, length: length, position: 3)
        let limit = length &+ 500

        let rowBytes = bytesPerRow
        let tileRowBytes = (rowBytes << 3) & 0xffff_ffff
        let recordSize = ScreenMVS.tileRecordSize
        for i in 0..<64 {
            UnsafeMutableRawPointer(edgeTile).storeBytes(of: ScreenMVS.opaque.littleEndian,
                                                         toByteOffset: i * 4, as: UInt32.self)
        }

        // The columns that were drawn into, to report less than the whole rectangle.
        var minX = x &+ w &+ 100
        var maxX = x &- 100

        var xOffset = 0
        var yOffset = 0
        var rowIndex = (y >> 3) * tilesPerRow + (x >> 3)
        var index = rowIndex
        var rowStart = rowBytes * y + 4 * x
        var destination = rowStart

        while true {
            let columns = w &- xOffset
            let rows = h &- yOffset
            let clipped = columns < 8 || rows < 8
            let out: UnsafeMutableRawPointer
            let stride: Int
            if clipped {
                out = UnsafeMutableRawPointer(edgeTile)
                stride = 32
            } else {
                guard destination >= 0, destination &+ 7 &* rowBytes &+ 32 <= pictureLength else {
                    throw ScreenMVSError.malformedBody
                }
                out = picture + destination
                stride = rowBytes
            }
            var copyEdge = clipped
            guard index >= 0, index < tileCount else {
                throw ScreenMVSError.malformedBody
            }
            let record = records + index * recordSize
            var drawn = true

            switch data.get(2) {
            case 0:
                // Nothing new for this tile.
                drawn = false
            case 1:
                // More detail for a tile the last full update sent as a DCT tile. The result also
                // becomes the next tile cache entry.
                try readRefinement(&data, record: record, limitCr: limitCr, limitCb: limitCb)
                drawTile(to: out, stride)
                tileCacheWrittenCount = tileCacheWrittenCount &+ 1
                var entry = Int(tileCacheLastWritten) &+ 1
                if entry >= ScreenMVS.tileCacheEntryCount {
                    entry = entry == ScreenMVS.tileCacheEntryCount ? 1 : entry & 0xffff
                }
                tileCacheLastWritten = UInt16(truncatingIfNeeded: entry)
                if let cache = tileCache, entry < ScreenMVS.tileCacheEntryCount {
                    memcpy(cache + entry * ScreenMVS.tileCacheEntrySize, entryScratch, ScreenMVS.tileCacheEntrySize)
                }
            case 2:
                // Copy a tile again from the tile the full update copied it from, now that the source
                // may have changed. Only when both were last touched by the same full update.
                let rawRecord = UnsafeRawPointer(record)
                let serial = rawRecord.loadUnaligned(fromByteOffset: ScreenMVS.recordSerial, as: UInt32.self)
                let source = Int(Int32(littleEndian: rawRecord.loadUnaligned(fromByteOffset: ScreenMVS.recordSource,
                                                                             as: Int32.self)))
                let sourceOffset = Int(UInt32(littleEndian: rawRecord.loadUnaligned(
                    fromByteOffset: ScreenMVS.recordSourceOffset, as: UInt32.self)))
                if source >= 0 {
                    if source < tileCount,
                       UnsafeRawPointer(records + source * recordSize)
                        .loadUnaligned(fromByteOffset: ScreenMVS.recordSerial, as: UInt32.self) == serial {
                        copyTile(from: sourceOffset, in: picture, to: out, stride, skipRowsAbove: false)
                    } else {
                        copyEdge = false
                    }
                }
            default:
                // A tile cache entry: the one after the entry drawn last, or by number.
                let entry: Int
                if data.get(1) != 0 {
                    entry = (Int(tileCacheLastDrawn) &+ 1) & 0xffff
                } else {
                    let high = data.get(8)
                    entry = Int(high << 8 | data.get(8))
                }
                _ = drawCacheEntry(entry, to: out, stride)
            }

            if drawn {
                if x &+ xOffset < minX {
                    minX = x &+ xOffset
                }
                if x &+ 8 &+ xOffset > maxX {
                    maxX = x &+ 8 &+ xOffset
                }
                if clipped && copyEdge {
                    try copyEdgeTile(to: destination, in: picture, columns: min(columns, 8), rows: min(rows, 8))
                }
            }

            // On to the next tile.
            let nextX = xOffset &+ 8
            if w > nextX & 0xffff {
                xOffset = nextX
                destination = destination &+ 32
                index = index &+ 1
            } else {
                yOffset = yOffset &+ 8
                if h <= yOffset & 0xffff {
                    break
                }
                xOffset = 0
                rowIndex = rowIndex &+ tilesPerRow
                index = rowIndex
                rowStart = rowStart &+ tileRowBytes
                destination = rowStart
            }
            if data.position > limit {
                throw ScreenMVSError.malformedBody
            }
        }

        // The stream ends with the bytes "mvs". Apple's viewer reads them and only logs a mismatch.
        _ = data.get(8)
        _ = data.get(8)
        _ = data.get(8)

        let changedWidth = min(maxX, x &+ w) &- minX
        return changedWidth > 0 && h > 0 ? (minX, y, changedWidth, h) : nil
    }

    /// The payload of a refined tile, read into `coefficients` and, as a tile cache entry, into `entryScratch`.
    ///
    /// Luma starts from the bytes the full update left in the tile's record and adds a few bits to each
    /// coefficient; chroma keeps its DC, give or take one, and gets its other coefficients Huffman coded.
    private func readRefinement(_ data: inout BitReader, record: UnsafeMutablePointer<UInt8>,
                                limitCr: Int, limitCb: Int) throws {
        let coefficients = self.coefficients
        let scratch = entryScratch
        memset(coefficients, 0, 192 * MemoryLayout<Int16>.size)
        memset(scratch, 0, ScreenMVS.tileCacheEntrySize)

        let oldCount = Int(record[ScreenMVS.recordLumaCount])
        coefficients[0] = Int16(Int8(bitPattern: record[ScreenMVS.recordLuma]))
        scratch[0] = record[ScreenMVS.recordLuma]
        let sent = Int(data.get(6))
        let newCount = sent &+ 1
        // Where the next saved coefficient is read in the record, and where the next result goes in the
        // entry. Both move on by one a coefficient whatever its position, as in Apple's viewer.
        var source = ScreenMVS.recordLuma + 1
        var stored = 1

        if oldCount < 15 {
            // Positions the full update already sent get three more bits.
            let both = min(newCount, oldCount)
            if both >= 2 {
                for i in 1..<both {
                    let value = refined(&data, record, &source, bits: 3)
                    store(value, at: i, &stored)
                }
            }
            // Positions that are new to this tile get four.
            if oldCount <= sent {
                var i = oldCount
                repeat {
                    let value = refined(&data, record, &source, bits: 4)
                    store(value, at: i, &stored)
                    i = i &+ 1
                } while i != newCount
            }
        } else {
            if sent != 0 {
                // The full update sent these almost exactly: one more bit.
                let both = min(newCount, oldCount)
                var i = 1
                repeat {
                    let old = Int(Int8(bitPattern: source < ScreenMVS.tileRecordSize ? record[source] : 0))
                    source = source &+ 1
                    let value: UInt8
                    if old != 0 {
                        let bit = Int(data.get(1))
                        value = UInt8(truncatingIfNeeded: old >= 0 ? old &+ bit : old &- bit)
                    } else if data.get(1) == 0 {
                        value = 0
                    } else {
                        value = data.get(1) != 0 ? 0xff : 1
                    }
                    store(value, at: i, &stored)
                    i = i &+ 1
                } while i != both
            }
            if oldCount <= sent {
                var i = oldCount
                repeat {
                    let value = refined(&data, record, &source, bits: 3)
                    store(value, at: i, &stored)
                    i = i &+ 1
                } while i != newCount
            }
        }

        // Red-difference plane first, then blue-difference.
        try readChroma(&data, record: record, marker: ScreenMVS.recordCrMarker, dc: ScreenMVS.recordCrDC,
                       plane: 128, limit: limitCr, entryOffset: 64, entryCount: 15)
        try readChroma(&data, record: record, marker: ScreenMVS.recordCbMarker, dc: ScreenMVS.recordCbDC,
                       plane: 64, limit: limitCb, entryOffset: 79, entryCount: 20)
    }

    /// One refined luma coefficient: the saved byte moved away from zero by `bits` bits of the stream,
    /// or a whole value when the saved byte is zero.
    @inline(__always)
    private func refined(_ data: inout BitReader, _ record: UnsafeMutablePointer<UInt8>, _ source: inout Int,
                         bits: Int) -> UInt8 {
        let old = Int(Int8(bitPattern: source < ScreenMVS.tileRecordSize ? record[source] : 0))
        source = source &+ 1
        if old == 0 {
            // A value that does not end is taken as 0.
            return UInt8(truncatingIfNeeded: data.signedValue() ?? 0)
        }
        let more = Int(data.get(bits))
        return UInt8(truncatingIfNeeded: old >= 0 ? old &+ more : old &- more)
    }

    /// Puts a refined luma coefficient at zig-zag position `i` and appends it to the tile cache entry.
    @inline(__always)
    private func store(_ value: UInt8, at i: Int, _ stored: inout Int) {
        coefficients[Int(zigzag[i & 63])] = Int16(Int8(bitPattern: value))
        if stored < ScreenMVS.tileCacheEntrySize {
            entryScratch[stored] = value
        }
        stored = stored &+ 1
    }

    /// One chroma plane of a refined tile.
    private func readChroma(_ data: inout BitReader, record: UnsafeMutablePointer<UInt8>, marker: Int, dc: Int,
                            plane: Int, limit: Int, entryOffset: Int, entryCount: Int) throws {
        // The tile must have been sent as a DCT tile.
        if record[marker] != 1 {
            throw ScreenMVSError.malformedBody
        }
        let old = Int(Int8(bitPattern: record[dc]))
        let bit = Int(data.get(1))
        let value: Int
        if old != 0 {
            value = old < 0 ? old &- bit : old &+ bit
        } else if bit != 0 {
            value = data.get(1) != 0 ? -1 : 1
        } else {
            value = 0
        }
        let coefficients = self.coefficients
        coefficients[plane] = Int16(Int8(truncatingIfNeeded: value))

        // The other coefficients: JPEG's run and size symbols, then the value's bits.
        if limit != 0 {
            var k = 0
            repeat {
                let symbol = Int(data.huffmanSymbol(lookLength: huffmanLookLength, lookSymbol: huffmanLookSymbol,
                                                    maxCode: huffmanMaxCode, valueOffset: huffmanValueOffset,
                                                    symbols: huffmanSymbols))
                let run = symbol >> 4
                let size = symbol & 15
                if size != 0 {
                    var v = Int(data.get(size))
                    if v < (1 << size) >> 1 {
                        v = v &+ 1 &- (1 << size)
                    }
                    k = k &+ run
                    let position = k &+ 1
                    if position < 80 {
                        coefficients[plane &+ Int(zigzag[position])] = Int16(truncatingIfNeeded: v)
                    }
                    k = k &+ 1
                } else {
                    if run != 15 {
                        break
                    }
                    k = k &+ 16
                }
            } while k < limit
        }
        for k in 0..<entryCount {
            entryScratch[entryOffset + k] = UInt8(truncatingIfNeeded: coefficients[plane + Int(zigzag[k])])
        }
    }

    // MARK: Tile cache

    /// Draws a tile from a tile cache entry. An entry that was never written draws nothing.
    private func drawCacheEntry(_ number: Int, to out: UnsafeMutableRawPointer, _ stride: Int) -> Bool {
        let entry = number & 0xffff
        if entry == 0 || entry > ScreenMVS.tileCacheEntryCount || Int(tileCacheWrittenCount) < entry {
            return false
        }
        guard let cache = tileCache else {
            return false
        }
        let coefficients = self.coefficients
        memset(coefficients, 0, 192 * MemoryLayout<Int16>.size)
        // Entry 65000 passes the check above but lies past the last entry: it reads as zeros.
        if entry < ScreenMVS.tileCacheEntryCount {
            let bytes = cache + entry * ScreenMVS.tileCacheEntrySize
            for i in 0..<64 {
                coefficients[Int(zigzag[i])] = Int16(Int8(bitPattern: bytes[i]))
            }
            for i in 0..<15 {
                coefficients[128 + Int(zigzag[i])] = Int16(Int8(bitPattern: bytes[64 + i]))
            }
            for i in 0..<20 {
                coefficients[64 + Int(zigzag[i])] = Int16(Int8(bitPattern: bytes[79 + i]))
            }
        }
        drawTile(to: out, stride)
        tileCacheLastDrawn = UInt16(truncatingIfNeeded: entry)
        return true
    }

    // MARK: Drawing

    /// Fills a tile with one pixel value.
    @inline(__always)
    private func fill(_ out: UnsafeMutableRawPointer, _ stride: Int, _ value: UInt32) {
        let pair = (UInt64(value) | UInt64(value) << 32).littleEndian
        for row in 0..<8 {
            let line = out + row &* stride
            line.storeBytes(of: pair, toByteOffset: 0, as: UInt64.self)
            line.storeBytes(of: pair, toByteOffset: 8, as: UInt64.self)
            line.storeBytes(of: pair, toByteOffset: 16, as: UInt64.self)
            line.storeBytes(of: pair, toByteOffset: 24, as: UInt64.self)
        }
    }

    /// One row of a tile with one bit a pixel, leftmost pixel in the highest bit: `set` where the bit is 1.
    @inline(__always)
    private func twoColourRow(_ line: UnsafeMutableRawPointer, _ bits: UInt32, _ set: UInt32, _ clear: UInt32) {
        for column in 0..<8 {
            let value = bits & (0x80 >> UInt32(column)) != 0 ? set : clear
            line.storeBytes(of: value.littleEndian, toByteOffset: column &* 4, as: UInt32.self)
        }
    }

    /// Copies the 8 rows of 32 bytes that start `source` bytes into the picture to a tile, a row at a time
    /// (source and destination may overlap). Bytes outside the picture read as zeros.
    /// With `skipRowsAbove`, rows that start before the picture are not copied at all.
    private func copyTile(from source: Int, in picture: UnsafeMutableRawPointer, to out: UnsafeMutableRawPointer,
                          _ stride: Int, skipRowsAbove: Bool) {
        let rowBytes = bytesPerRow
        let opaque = ScreenMVS.opaquePair
        if source >= 0 && source &+ 7 &* rowBytes &+ 32 <= pictureLength {
            for row in 0..<8 {
                let from = UnsafeRawPointer(picture) + (source &+ row &* rowBytes)
                let a = from.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
                let b = from.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                let c = from.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
                let d = from.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
                let line = out + row &* stride
                line.storeBytes(of: a | opaque, toByteOffset: 0, as: UInt64.self)
                line.storeBytes(of: b | opaque, toByteOffset: 8, as: UInt64.self)
                line.storeBytes(of: c | opaque, toByteOffset: 16, as: UInt64.self)
                line.storeBytes(of: d | opaque, toByteOffset: 24, as: UInt64.self)
            }
            return
        }
        for row in 0..<8 {
            let start = source &+ row &* rowBytes
            if skipRowsAbove && start < 0 {
                continue
            }
            let line = out + row &* stride
            if start >= 0 && start &+ 32 <= pictureLength {
                // Read the whole row before writing it: the two may overlap.
                let from = UnsafeRawPointer(picture) + start
                let a = from.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
                let b = from.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                let c = from.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
                let d = from.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
                line.storeBytes(of: a | opaque, toByteOffset: 0, as: UInt64.self)
                line.storeBytes(of: b | opaque, toByteOffset: 8, as: UInt64.self)
                line.storeBytes(of: c | opaque, toByteOffset: 16, as: UInt64.self)
                line.storeBytes(of: d | opaque, toByteOffset: 24, as: UInt64.self)
            } else {
                var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
                withUnsafeMutableBytes(of: &bytes) { row in
                    for i in 0..<32 {
                        let at = start &+ i
                        row[i] = at >= 0 && at < pictureLength ? picture.load(fromByteOffset: at, as: UInt8.self) : 0
                    }
                }
                line.storeBytes(of: bytes.0 | opaque, toByteOffset: 0, as: UInt64.self)
                line.storeBytes(of: bytes.1 | opaque, toByteOffset: 8, as: UInt64.self)
                line.storeBytes(of: bytes.2 | opaque, toByteOffset: 16, as: UInt64.self)
                line.storeBytes(of: bytes.3 | opaque, toByteOffset: 24, as: UInt64.self)
            }
        }
    }

    /// Copies the visible part of a clipped tile from `edgeTile` to the picture.
    private func copyEdgeTile(to destination: Int, in picture: UnsafeMutableRawPointer,
                              columns: Int, rows: Int) throws {
        if rows < 1 || columns < 1 {
            return
        }
        guard destination >= 0, destination &+ (rows &- 1) &* bytesPerRow &+ columns &* 4 <= pictureLength else {
            throw ScreenMVSError.malformedBody
        }
        for row in 0..<rows {
            memcpy(picture + (destination &+ row &* bytesPerRow), edgeTile + row &* 32, columns &* 4)
        }
    }

    /// What a red-difference sample adds to red: the usual JPEG conversion from YCbCr, in 16.16 fixed point.
    @inline(__always)
    private static func red(_ cr: Int32) -> Int32 {
        return (91881 &* (cr &- 128) &+ 32768) >> 16
    }

    /// What the two chroma samples add to green.
    @inline(__always)
    private static func green(_ cb: Int32, _ cr: Int32) -> Int32 {
        return (-22554 &* (cb &- 128) &+ 32768 &- 46802 &* (cr &- 128)) >> 16
    }

    /// What a blue-difference sample adds to blue.
    @inline(__always)
    private static func blue(_ cb: Int32) -> Int32 {
        return (116130 &* (cb &- 128) &+ 32768) >> 16
    }

    /// A colour value limited to 0...255.
    @inline(__always)
    private static func limited(_ value: Int32) -> UInt32 {
        return UInt32(truncatingIfNeeded: max(0, min(255, value)))
    }

    /// The pixels of one column of a tile from its luma samples and what chroma adds to each colour.
    @inline(__always)
    private static func pixels(_ y: SIMD8<Int32>, _ red: SIMD8<Int32>, _ green: SIMD8<Int32>,
                               _ blue: SIMD8<Int32>) -> SIMD8<UInt32> {
        let lowest = SIMD8<Int32>(repeating: 0)
        let highest = SIMD8<Int32>(repeating: 255)
        let b = (y &+ blue).clamped(lowerBound: lowest, upperBound: highest)
        let g = (y &+ green).clamped(lowerBound: lowest, upperBound: highest)
        let r = (y &+ red).clamped(lowerBound: lowest, upperBound: highest)
        return SIMD8<UInt32>(truncatingIfNeeded: b | g &<< 8 | r &<< 16) | SIMD8<UInt32>(repeating: opaque)
    }

    /// Writes the pixels in `pixelColumns`, which holds the tile column after column, into a tile row by row.
    @inline(__always)
    private func storePixelColumns(to out: UnsafeMutableRawPointer, _ stride: Int) {
        let columns = UnsafeRawPointer(pixelColumns)
        for row in 0..<8 {
            let line = out + row &* stride
            for column in 0..<8 {
                let value = columns.load(fromByteOffset: (column &* 8 &+ row) &* 4, as: UInt32.self)
                line.storeBytes(of: value.littleEndian, toByteOffset: column &* 4, as: UInt32.self)
            }
        }
    }

    /// Draws a DCT tile of a full update: 64 luma coefficients, and chroma that is the same all over the tile.
    private func drawBlock(luma: UnsafeMutablePointer<Int16>, cb: Int16, cr: Int16,
                           to out: UnsafeMutableRawPointer, _ stride: Int) {
        let cbSample = Int32(flatSample(cb, chromaQuantisation[0]))
        let crSample = Int32(flatSample(cr, chromaQuantisation[0]))
        let red = ScreenMVS.red(crSample)
        let green = ScreenMVS.green(cbSample, crSample)
        let blue = ScreenMVS.blue(cbSample)
        if ScreenMVS.hasOnlyDC(luma) {
            let y = Int32(flatSample(luma[0], lumaQuantisation[0]))
            let value = ScreenMVS.limited(y &+ blue) | ScreenMVS.limited(y &+ green) << 8
                | ScreenMVS.limited(y &+ red) << 16 | ScreenMVS.opaque
            fill(out, stride, value)
            return
        }
        // Luma has other coefficients: transform it, then colour a column of eight pixels at a time.
        let y = samples
        inverseDCT(luma, lumaQuantisation, y, mayBeFlat: false)
        let redColumn = SIMD8<Int32>(repeating: red)
        let greenColumn = SIMD8<Int32>(repeating: green)
        let blueColumn = SIMD8<Int32>(repeating: blue)
        for column in 0..<8 {
            pixelColumns[column] = ScreenMVS.pixels(y[column], redColumn, greenColumn, blueColumn)
        }
        storePixelColumns(to: out, stride)
    }

    /// Draws a tile from the three planes in `coefficients`.
    private func drawTile(to out: UnsafeMutableRawPointer, _ stride: Int) {
        let y = samples
        let cb = samples + 8
        let cr = samples + 16
        inverseDCT(coefficients, lumaQuantisation, y, mayBeFlat: true)
        inverseDCT(coefficients + 64, chromaQuantisation, cb, mayBeFlat: true)
        inverseDCT(coefficients + 128, chromaQuantisation, cr, mayBeFlat: true)
        // The conversion of `red`, `green` and `blue`, for the eight pixels of a column at once.
        for column in 0..<8 {
            let blueDifference = cb[column] &- 128
            let redDifference = cr[column] &- 128
            let red = (redDifference &* 91881 &+ 32768) &>> 16
            let green = (blueDifference &* -22554 &+ 32768 &- redDifference &* 46802) &>> 16
            let blue = (blueDifference &* 116130 &+ 32768) &>> 16
            pixelColumns[column] = ScreenMVS.pixels(y[column], red, green, blue)
        }
        storePixelColumns(to: out, stride)
    }

    // MARK: Inverse DCT

    /// Whether every coefficient of a plane but the first is zero.
    @inline(__always)
    private static func hasOnlyDC(_ plane: UnsafePointer<Int16>) -> Bool {
        let raw = UnsafeRawPointer(plane)
        // 64 coefficients of 16 bits are 16 words of 64; the first 16 bits in memory are the DC.
        var any = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self) & ~UInt64(littleEndian: 0xffff)
        for word in 1..<16 {
            any |= raw.loadUnaligned(fromByteOffset: word &* 8, as: UInt64.self)
        }
        return any == 0
    }

    /// The sample every pixel gets when a plane has only its DC coefficient: what the inverse DCT below
    /// gives for such a plane, without the work.
    @inline(__always)
    private func flatSample(_ dc: Int16, _ quantisation: Int32) -> UInt8 {
        let scaled = (Int32(dc) &* quantisation) &<< 2
        return rangeLimit[Int((scaled &+ 16) >> 5) & 0x3ff]
    }

    /// The last step of the inverse DCT for eight values at once: drops 18 bits, keeps the next 10 as a
    /// signed number, adds 128 and limits to 0...255. The same as looking the 10 bits up in `rangeLimit`.
    @inline(__always)
    private static func descaled(_ value: SIMD8<Int32>) -> SIMD8<Int32> {
        let rounded = value &+ SIMD8<Int32>(repeating: 1 << 17)
        return (((rounded &<< 4) &>> 22) &+ 128).clamped(lowerBound: SIMD8<Int32>(repeating: 0),
                                                         upperBound: SIMD8<Int32>(repeating: 255))
    }

    /// The inverse DCT of one plane: the accurate integer method of the JPEG reference code (13 bits of
    /// constants, 2 extra bits between the passes), in wrapping 32-bit arithmetic, with the coefficients
    /// scaled by the quantisation table on the way in.
    ///
    /// Writes eight vectors: one for each column of the tile, with that column's samples from the top down.
    /// With `mayBeFlat` a plane that has only its first coefficient is found first and done the short way.
    private func inverseDCT(_ coefficients: UnsafePointer<Int16>, _ quantisation: UnsafePointer<Int32>,
                            _ output: UnsafeMutablePointer<SIMD8<Int32>>, mayBeFlat: Bool) {
        if mayBeFlat && ScreenMVS.hasOnlyDC(coefficients) {
            let flat = SIMD8<Int32>(repeating: Int32(flatSample(coefficients[0], quantisation[0])))
            for column in 0..<8 {
                output[column] = flat
            }
            return
        }
        let ws = workspace

        // Columns, one at a time. The results of column c go to ws[c * 8 ...], top row first.
        for c in 0..<8 {
            let c0 = Int32(coefficients[c])
            let c1 = Int32(coefficients[8 &+ c])
            let c2 = Int32(coefficients[16 &+ c])
            let c3 = Int32(coefficients[24 &+ c])
            let c4 = Int32(coefficients[32 &+ c])
            let c5 = Int32(coefficients[40 &+ c])
            let c6 = Int32(coefficients[48 &+ c])
            let c7 = Int32(coefficients[56 &+ c])
            let column = ws + c &* 8
            if (c1 | c2 | c3 | c4 | c5 | c6 | c7) == 0 {
                // A column with only its first coefficient. This is not the same as the long way below
                // once values wrap, and Apple's viewer takes this way.
                let dc = (c0 &* quantisation[c]) &<< 2
                column[0] = dc
                column[1] = dc
                column[2] = dc
                column[3] = dc
                column[4] = dc
                column[5] = dc
                column[6] = dc
                column[7] = dc
                continue
            }
            var z2 = c2 &* quantisation[16 &+ c]
            var z3 = c6 &* quantisation[48 &+ c]
            var z1 = (z2 &+ z3) &* 4433
            var tmp2 = z1 &+ z3 &* -15137
            var tmp3 = z1 &+ z2 &* 6270
            z2 = c0 &* quantisation[c]
            z3 = c4 &* quantisation[32 &+ c]
            var tmp0 = (z2 &+ z3) &<< 13
            var tmp1 = (z2 &- z3) &<< 13
            let tmp10 = tmp0 &+ tmp3
            let tmp13 = tmp0 &- tmp3
            let tmp11 = tmp1 &+ tmp2
            let tmp12 = tmp1 &- tmp2
            tmp0 = c7 &* quantisation[56 &+ c]
            tmp1 = c5 &* quantisation[40 &+ c]
            tmp2 = c3 &* quantisation[24 &+ c]
            tmp3 = c1 &* quantisation[8 &+ c]
            z1 = tmp0 &+ tmp3
            z2 = tmp1 &+ tmp2
            z3 = tmp0 &+ tmp2
            var z4 = tmp1 &+ tmp3
            let z5 = (z3 &+ z4) &* 9633
            tmp0 = tmp0 &* 2446
            tmp1 = tmp1 &* 16819
            tmp2 = tmp2 &* 25172
            tmp3 = tmp3 &* 12299
            z1 = z1 &* -7373
            z2 = z2 &* -20995
            z3 = z3 &* -16069
            z4 = z4 &* -3196
            z3 = z3 &+ z5
            z4 = z4 &+ z5
            tmp0 = tmp0 &+ z1 &+ z3
            tmp1 = tmp1 &+ z2 &+ z4
            tmp2 = tmp2 &+ z2 &+ z3
            tmp3 = tmp3 &+ z1 &+ z4
            column[0] = (tmp10 &+ tmp3 &+ 1024) >> 11
            column[7] = (tmp10 &- tmp3 &+ 1024) >> 11
            column[1] = (tmp11 &+ tmp2 &+ 1024) >> 11
            column[6] = (tmp11 &- tmp2 &+ 1024) >> 11
            column[2] = (tmp12 &+ tmp1 &+ 1024) >> 11
            column[5] = (tmp12 &- tmp1 &+ 1024) >> 11
            column[3] = (tmp13 &+ tmp0 &+ 1024) >> 11
            column[4] = (tmp13 &- tmp0 &+ 1024) >> 11
        }

        // Rows, all eight at once: each vector holds one value of every row. Apple's viewer has a short
        // way for a row with only its first value; here that gives the same sample as the long way,
        // because only 10 bits of the result are kept.
        let raw = UnsafeRawPointer(ws)
        let w0 = raw.loadUnaligned(fromByteOffset: 0, as: SIMD8<Int32>.self)
        let w1 = raw.loadUnaligned(fromByteOffset: 32, as: SIMD8<Int32>.self)
        let w2 = raw.loadUnaligned(fromByteOffset: 64, as: SIMD8<Int32>.self)
        let w3 = raw.loadUnaligned(fromByteOffset: 96, as: SIMD8<Int32>.self)
        let w4 = raw.loadUnaligned(fromByteOffset: 128, as: SIMD8<Int32>.self)
        let w5 = raw.loadUnaligned(fromByteOffset: 160, as: SIMD8<Int32>.self)
        let w6 = raw.loadUnaligned(fromByteOffset: 192, as: SIMD8<Int32>.self)
        let w7 = raw.loadUnaligned(fromByteOffset: 224, as: SIMD8<Int32>.self)
        let even = (w2 &+ w6) &* 4433
        var tmp2 = even &+ w6 &* -15137
        var tmp3 = even &+ w2 &* 6270
        var tmp0 = (w0 &+ w4) &<< 13
        var tmp1 = (w0 &- w4) &<< 13
        let tmp10 = tmp0 &+ tmp3
        let tmp13 = tmp0 &- tmp3
        let tmp11 = tmp1 &+ tmp2
        let tmp12 = tmp1 &- tmp2
        tmp0 = w7
        tmp1 = w5
        tmp2 = w3
        tmp3 = w1
        var z1 = tmp0 &+ tmp3
        var z2 = tmp1 &+ tmp2
        var z3 = tmp0 &+ tmp2
        var z4 = tmp1 &+ tmp3
        let z5 = (z3 &+ z4) &* 9633
        tmp0 = tmp0 &* 2446
        tmp1 = tmp1 &* 16819
        tmp2 = tmp2 &* 25172
        tmp3 = tmp3 &* 12299
        z1 = z1 &* -7373
        z2 = z2 &* -20995
        z3 = z3 &* -16069
        z4 = z4 &* -3196
        z3 = z3 &+ z5
        z4 = z4 &+ z5
        tmp0 = tmp0 &+ z1 &+ z3
        tmp1 = tmp1 &+ z2 &+ z4
        tmp2 = tmp2 &+ z2 &+ z3
        tmp3 = tmp3 &+ z1 &+ z4
        output[0] = ScreenMVS.descaled(tmp10 &+ tmp3)
        output[7] = ScreenMVS.descaled(tmp10 &- tmp3)
        output[1] = ScreenMVS.descaled(tmp11 &+ tmp2)
        output[6] = ScreenMVS.descaled(tmp11 &- tmp2)
        output[2] = ScreenMVS.descaled(tmp12 &+ tmp1)
        output[5] = ScreenMVS.descaled(tmp12 &- tmp1)
        output[3] = ScreenMVS.descaled(tmp13 &+ tmp0)
        output[4] = ScreenMVS.descaled(tmp13 &- tmp0)
    }

    // MARK: Constant data

    /// Zig-zag position to position in row order.
    private static let zigzagOrder: [UInt8] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    /// The luma quantisation table used until the server sends one, in row order.
    private static let defaultLumaQuantisation: [UInt8] = [
        16, 11, 11, 14, 24, 22, 24, 33, 11, 12, 11, 11, 26, 18, 19, 23,
        13, 13, 14, 24, 20, 21, 22, 28, 13, 17, 14, 21, 23, 25, 34, 34,
        17, 22, 18, 25, 31, 32, 34, 44, 24, 20, 17, 27, 35, 40, 44, 54,
        30, 35, 28, 30, 34, 44, 54, 64, 35, 30, 33, 38, 45, 55, 65, 75,
    ]

    /// The chroma quantisation table used until the server sends one, in row order.
    private static let defaultChromaQuantisation: [UInt8] = [
        19, 19, 24, 47, 76, 99, 99, 99, 19, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
        76, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    ]

    /// JPEG's standard Huffman table for luma AC coefficients: how many codes there are of each length
    /// from 1 to 16 bits. It is the only table the format uses, for both chroma planes.
    private static let huffmanCodeCounts: [Int] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d]

    /// The symbols of that table, shortest code first: run of zeros in the high four bits, size in the low.
    private static let huffmanCodeSymbols: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
        0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
        0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
        0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45,
        0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
        0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
        0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
        0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4,
        0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
    ]

    /// Builds the decoding tables for the Huffman code above, the way the JPEG reference code does.
    private static func buildHuffmanTables(lookLength: UnsafeMutablePointer<UInt8>,
                                           lookSymbol: UnsafeMutablePointer<UInt8>,
                                           maxCode: UnsafeMutablePointer<Int32>,
                                           valueOffset: UnsafeMutablePointer<Int32>,
                                           symbols: UnsafeMutablePointer<UInt8>) {
        symbols.initialize(repeating: 0, count: 256)
        for (i, symbol) in huffmanCodeSymbols.enumerated() {
            symbols[i] = symbol
        }
        // Codes are numbered upwards, shortest first.
        var codes: [Int32] = []
        var code: Int32 = 0
        for length in 1...16 {
            for _ in 0..<huffmanCodeCounts[length - 1] {
                codes.append(code)
                code += 1
            }
            code <<= 1
        }
        var p = 0
        maxCode[0] = -1
        valueOffset[0] = 0
        for length in 1...16 {
            let count = huffmanCodeCounts[length - 1]
            if count > 0 {
                valueOffset[length] = Int32(p) - codes[p]
                p += count
                maxCode[length] = codes[p - 1]
            } else {
                valueOffset[length] = 0
                maxCode[length] = -1
            }
        }
        maxCode[17] = 0xfffff
        lookLength.initialize(repeating: 0, count: 256)
        lookSymbol.initialize(repeating: 0, count: 256)
        p = 0
        for length in 1...8 {
            for _ in 0..<huffmanCodeCounts[length - 1] {
                let first = Int(codes[p]) << (8 - length)
                for extra in 0..<(1 << (8 - length)) {
                    lookLength[first + extra] = UInt8(length)
                    lookSymbol[first + extra] = huffmanCodeSymbols[p]
                }
                p += 1
            }
        }
    }
}

/// What one code for a luma coefficient of a full update says.
private enum CoefficientCode {
    /// The coefficient's value before scaling.
    case value(Int)
    /// This many positions are zero; 64 for the rest of the tile.
    case skip(Int)
    /// A code Apple's viewer refuses.
    case invalid
    /// A code that makes Apple's viewer stop reading the tile.
    case stop
}

/// Reads bits from a body, highest bit of each byte first.
///
/// It keeps up to 32 bits and takes whole bytes only when it has fewer than are asked for, until it
/// has more than 24. `position` is therefore up to three bytes ahead of the bits handed out, as in
/// Apple's viewer, whose checks for a stream that ran past the body compare this position.
/// Bytes past the end of the body read as zeros.
private struct BitReader {
    private let bytes: UnsafePointer<UInt8>
    private let length: Int
    /// The next byte to take from the body.
    private(set) var position: Int
    private var bits: UInt32 = 0
    private var count = 0

    init(_ bytes: UnsafePointer<UInt8>, length: Int, position: Int) {
        self.bytes = bytes
        self.length = length
        self.position = position
    }

    @inline(__always)
    private mutating func refill() {
        repeat {
            let p = position
            position = p &+ 1
            let byte: UInt32 = p >= 0 && p < length ? UInt32(bytes[p]) : 0
            bits |= byte &<< UInt32(truncatingIfNeeded: 24 &- count)
            count = count &+ 8
        } while count <= 24
    }

    /// The next `n` bits, 1 to 25 of them.
    @inline(__always)
    mutating func get(_ n: Int) -> UInt32 {
        if count < n {
            refill()
        }
        let value = bits &>> UInt32(truncatingIfNeeded: 32 &- n)
        bits = bits &<< UInt32(truncatingIfNeeded: n)
        count = count &- n
        return value
    }

    /// Reads one bits until a zero bit, or until `most` of them were read and then one bit more
    /// whatever it is: what single reads in a loop do, a buffer at a time.
    @inline(__always)
    mutating func ones(atMost most: Int) -> Int {
        var found = 0
        while true {
            // Below the buffered bits the buffer holds zeros, so this never counts past them.
            let run = min((~bits).leadingZeroBitCount, most &- found)
            found = found &+ run
            // All 32 bits can go at once here, which a masking shift would not do.
            bits = bits << UInt32(truncatingIfNeeded: run)
            count = count &- run
            if found >= most {
                _ = get(1)
                return found
            }
            if count > 0 {
                // The zero that ends the ones is buffered: take it.
                bits = bits &<< 1
                count = count &- 1
                return found
            }
            // Every buffered bit was a one. A single read would fill the buffer now.
            refill()
        }
    }

    /// How many more tiles a command of a full update covers after the first:
    /// 0, or 1 and four bits for 1 to 15, or 1 1111 and up to three bytes for 16 and more.
    @inline(__always)
    mutating func repeatCount() -> Int {
        if get(1) == 0 {
            return 0
        }
        let short = get(4)
        if short != 15 {
            return Int(short) &+ 1
        }
        let b0 = Int(get(8))
        if b0 & 0x80 == 0 {
            return b0 &+ 16
        }
        let b1 = Int(get(8))
        if b1 & 0x80 == 0 {
            return (b1 << 7 | b0 & 0x7f) &+ 16
        }
        // The third byte counts in full: its high bit does not ask for a fourth.
        let b2 = Int(get(8))
        return (b2 << 14 | (b1 & 0x7f) << 7 | b0 & 0x7f) &+ 16
    }

    /// A signed value: ones that count its size, a zero, value bits, and a sign bit that is 1 for negative.
    /// nil after 39 ones.
    @inline(__always)
    mutating func signedValue() -> Int? {
        let ones = self.ones(atMost: 39)
        if ones == 39 {
            return nil
        }
        let value: Int
        let negative: Bool
        switch ones {
        case 0:
            if get(1) == 0 {
                return 0
            }
            negative = get(1) != 0
            value = 1
        case 1:
            let tail = Int(get(2))
            value = 2 | tail >> 1
            negative = tail & 1 != 0
        case 2:
            let tail = Int(get(3))
            value = 4 | tail >> 1
            negative = tail & 1 != 0
        default:
            let tail = Int(get(4))
            value = ((ones &+ 1) & 0xff) &* 8 &+ (tail >> 1) &- 0x18
            negative = tail & 1 != 0
        }
        return negative ? -value : value
    }

    /// One code for a luma coefficient of a full update:
    ///
    ///     0 00            a zero
    ///     0 10, 0 11      plus one, minus one
    ///     0 01 0          the rest of the tile is zero
    ///     0 01 1 zz       a run of zeros: zz + 3 of them, or with zz = 3 six plus 3-bit numbers that
    ///                     go on while they are 7
    ///     1 ...           a larger value: ones that count its size, a zero, value bits, a sign bit
    ///
    /// Zig-zag positions 1 to 5 (`early`) count sizes differently from the positions after them.
    /// `i` is the position the code starts at.
    @inline(__always)
    mutating func coefficientCode(early: Bool, at i: Int) -> CoefficientCode {
        if get(1) == 0 {
            switch get(2) {
            case 0:
                return .value(0)
            case 1:
                if get(1) == 0 {
                    return .skip(64)
                }
                let short = Int(get(2))
                var zeros = short &+ 3
                if short != 3 {
                    // A run past the last position just ends the tile.
                    return .skip(zeros)
                }
                var next = i
                while true {
                    let more = Int(get(3))
                    zeros = zeros &+ more
                    next = i &+ (zeros & 0xff)
                    if more == 7 && next < 64 {
                        continue
                    }
                    break
                }
                // This kind of run must stay inside the tile.
                return next >= 64 ? .invalid : .skip(next &- i)
            case 2:
                return .value(1)
            default:
                return .value(-1)
            }
        }
        let tail: Int
        let magnitude: Int
        if early {
            let ones = self.ones(atMost: 33)
            if ones == 33 {
                return .invalid
            }
            if ones <= 3 {
                tail = Int(get(3))
                magnitude = (ones &+ 1) &* 4 &+ (tail >> 1) &- 2
            } else {
                tail = Int(get(4))
                magnitude = (ones &+ 1) &* 8 &+ (tail >> 1) &- 22
            }
        } else {
            let ones = self.ones(atMost: 19)
            if ones == 19 {
                return .stop
            }
            if ones == 0 {
                tail = Int(get(2))
                magnitude = 2 | (tail >> 1)
            } else if ones == 1 {
                tail = Int(get(3))
                magnitude = 4 | (tail >> 1)
            } else {
                tail = Int(get(4))
                magnitude = ((ones &+ 1) & 0xff) &* 8 &+ (tail >> 1) &- 16
            }
        }
        return .value(tail & 1 != 0 ? -magnitude : magnitude)
    }

    /// The next Huffman symbol: by table when its code is 8 bits or shorter, bit by bit otherwise.
    /// A code that does not exist gives 0.
    mutating func huffmanSymbol(lookLength: UnsafePointer<UInt8>, lookSymbol: UnsafePointer<UInt8>,
                                maxCode: UnsafePointer<Int32>, valueOffset: UnsafePointer<Int32>,
                                symbols: UnsafePointer<UInt8>) -> UInt8 {
        if count <= 7 {
            refill()
        }
        let look = Int(bits &>> 24)
        let short = Int(lookLength[look])
        if short != 0 {
            bits = bits &<< UInt32(truncatingIfNeeded: short)
            count = count &- short
            return lookSymbol[look]
        }
        var code = Int32(truncatingIfNeeded: get(9))
        var length = 9
        while length < 17 && code > maxCode[length] {
            code = code &<< 1 | Int32(truncatingIfNeeded: get(1))
            length = length &+ 1
        }
        if length > 16 {
            return 0
        }
        let index = Int(code &+ valueOffset[length])
        return index >= 0 && index < 162 ? symbols[index] : 0
    }
}
