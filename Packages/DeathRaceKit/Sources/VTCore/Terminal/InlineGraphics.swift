import Foundation

public struct InlineImage: Sendable, Equatable {
    public enum Format: UInt32, Sendable { case rgb = 24, rgba = 32, png = 100 }
    public static let maximumBytes = 4 << 20
    public static let maximumPixels = 1 << 20
    public let id: UInt32
    public let revision: UInt64
    public let format: Format
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(id: UInt32, revision: UInt64, format: Format, width: Int, height: Int, bytes: [UInt8]) {
        self.id = id; self.revision = revision; self.format = format
        self.width = width; self.height = height; self.bytes = bytes
    }

    public var isValid: Bool {
        guard id != 0, width > 0, height > 0, width <= 4096, height <= 4096,
            width * height <= Self.maximumPixels, bytes.count <= Self.maximumBytes
        else { return false }
        if format == .png {
            guard let size = Self.pngSize(bytes) else { return false }
            return size == (width, height)
        }
        return bytes.count == width * height * (format == .rgb ? 3 : 4)
    }

    public static func pngSize(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 33, Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
            Array(bytes[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82]
        else { return nil }
        func word(_ offset: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) } }
        return (word(16), word(20))
    }
}

public struct InlinePlacement: Sendable, Equatable {
    public let imageID: UInt32
    public let placementID: UInt32
    public var line: UInt64
    public var column: Int
    public let columns: Int
    public let rows: Int
    public let alternate: Bool
    public let zIndex: Int32
    public init(
        imageID: UInt32, placementID: UInt32 = 0, line: UInt64, column: Int,
        columns: Int, rows: Int, alternate: Bool = false, zIndex: Int32 = 0
    ) {
        self.imageID = imageID; self.placementID = placementID; self.line = line
        self.column = column; self.columns = columns; self.rows = rows
        self.alternate = alternate; self.zIndex = zIndex
    }
    public var key: UInt64 { UInt64(imageID) << 32 | UInt64(placementID) }
    public var isValid: Bool {
        imageID > 0 && column >= 0 && column < 10_000 && columns > 0 && columns <= 10_000
            && rows > 0 && rows <= 1000 && line <= UInt64.max - UInt64(rows)
    }
}

/// Session-owned assets and placements, with one bounded chunked transmission at a time.
public struct InlineGraphics {
    public static let maximumImages = 32
    public static let maximumPlacements = 128
    public private(set) var images: [UInt32: InlineImage] = [:]
    public private(set) var placements: [UInt64: InlinePlacement] = [:]
    public private(set) var revision: UInt64 = 0
    private var partial: (fields: [String: String], bytes: [UInt8])?
    private var nextID: UInt32 = 0

    mutating func reset() {
        let next = revision &+ 1
        self = InlineGraphics()
        revision = next
    }

    mutating func transmit(fields: [String: String], bytes: [UInt8], revision: UInt64) throws -> (
        [String: String], InlineImage
    )? {
        var fields = fields
        var bytes = bytes
        if let pending = partial {
            partial = nil
            guard fields.allSatisfy({ $0.key == "m" || $0.key == "q" || pending.fields[$0.key] == $0.value }) else {
                throw GraphicsFailure("EINVAL")
            }
            guard bytes.count <= InlineImage.maximumBytes - pending.bytes.count else { throw GraphicsFailure("E2BIG") }
            bytes = pending.bytes + bytes
            fields = pending.fields.merging(fields) { _, new in new }
        }
        guard bytes.count <= InlineImage.maximumBytes else { throw GraphicsFailure("E2BIG") }
        if fields["m"] == "1" { partial = (fields, bytes); return nil }
        guard fields["t"] == nil || fields["t"] == "d", fields["o"] == nil,
            let format = InlineImage.Format(rawValue: UInt32(fields["f"] ?? "32") ?? 0)
        else { throw GraphicsFailure("ENOTSUP") }
        var id = UInt32(fields["i"] ?? "0") ?? 0
        if id == 0 { repeat { nextID &+= 1 } while nextID == 0 || images[nextID] != nil; id = nextID }
        let size =
            format == .png ? InlineImage.pngSize(bytes) : (Int(fields["s"] ?? "0") ?? 0, Int(fields["v"] ?? "0") ?? 0)
        guard let size else { throw GraphicsFailure("EINVAL") }
        let image = InlineImage(id: id, revision: revision, format: format, width: size.0, height: size.1, bytes: bytes)
        guard image.isValid else { throw GraphicsFailure("EINVAL") }
        return (fields, image)
    }

    mutating func store(_ image: InlineImage) {
        revision &+= 1
        images[image.id] = nil
        while images.count >= Self.maximumImages
            || images.values.reduce(0, { $0 + $1.bytes.count }) + image.bytes.count > InlineImage.maximumBytes
            || images.values.reduce(0, { $0 + $1.width * $1.height * 4 }) + image.width * image.height * 4
                > InlineImage.maximumBytes
        {
            guard let oldest = images.values.min(by: { $0.revision < $1.revision }) else { break }
            images[oldest.id] = nil
            placements = placements.filter { $0.value.imageID != oldest.id }
        }
        images[image.id] = image
    }

    mutating func place(_ placement: InlinePlacement) throws {
        guard placement.isValid else { throw GraphicsFailure("EINVAL") }
        guard placements[placement.key] != nil || placements.count < Self.maximumPlacements else {
            throw GraphicsFailure("E2BIG")
        }
        revision &+= 1
        placements[placement.key] = placement
    }

    mutating func remove(image: UInt32?, placement: UInt32?, data: Bool, alternate: Bool) {
        revision &+= 1
        placements = placements.filter { _, p in
            if let image { return p.imageID != image || (placement.map { p.placementID != $0 } ?? false) }
            return p.alternate != alternate
        }
        if data {
            if let image {
                images[image] = nil; placements = placements.filter { $0.value.imageID != image }
            } else {
                images = images.filter { id, _ in placements.values.contains { $0.imageID == id } }
            }
        }
    }

    mutating func prune(firstLine: UInt64) {
        let previous = placements.count
        placements = placements.filter { $0.value.alternate || $0.value.line + UInt64($0.value.rows) > firstLine }
        if placements.count != previous { revision &+= 1 }
    }
}

private struct GraphicsFailure: Error { let message: String; init(_ message: String) { self.message = message } }

extension Terminal {
    func applicationProgramCommand(_ payload: UnsafeBufferPointer<UInt8>) {
        guard payload.first == 71 else { return }  // Kitty's G, not another APC protocol.
        let bytes = Array(payload.dropFirst())
        let separator = bytes.firstIndex(of: 59) ?? bytes.endIndex
        guard separator <= 4096 else { return }
        let header = String(decoding: bytes[..<separator], as: UTF8.self)
        var fields: [String: String] = [:]
        for part in header.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, fields[String(pair[0])] == nil else { return }
            fields[String(pair[0])] = String(pair[1])
        }
        var response = "OK"
        var responseID = UInt32(fields["i"] ?? "0") ?? 0
        var quiet = Int(fields["q"] ?? "0") ?? 0
        do {
            let supported: Set<String> = ["a", "t", "f", "s", "v", "i", "p", "c", "r", "C", "m", "q", "z", "d"]
            guard Set(fields.keys).isSubset(of: supported) else { throw GraphicsFailure("ENOTSUP") }
            var action = fields["a"] ?? "t"
            if action == "d" {
                let kind = fields["d"] ?? "a"
                guard ["a", "A", "i", "I"].contains(kind) else { throw GraphicsFailure("ENOTSUP") }
                if kind.lowercased() == "i", responseID == 0 { throw GraphicsFailure("EINVAL") }
                inlineGraphics.remove(
                    image: kind.lowercased() == "i" ? responseID : nil,
                    placement: fields["p"].flatMap(UInt32.init), data: kind == kind.uppercased(),
                    alternate: isAlternateScreen)
            } else {
                var image: InlineImage?
                var effective = fields
                if action != "p" {
                    guard ["t", "T", "q"].contains(action), separator < bytes.count,
                        let decoded = Data(base64Encoded: Data(bytes[(separator + 1)...]))
                    else { throw GraphicsFailure("EINVAL") }
                    guard
                        let result = try inlineGraphics.transmit(
                            fields: fields, bytes: Array(decoded), revision: clock.tick())
                    else {
                        return
                    }
                    effective = result.0; image = result.1
                    quiet = Int(effective["q"] ?? "0") ?? 0
                    action = effective["a"] ?? action
                    responseID = result.1.id
                    if action != "q" { inlineGraphics.store(result.1) }
                } else {
                    image = inlineGraphics.images[responseID]
                }
                let placementAction = effective["a"] ?? action
                if placementAction == "T" || placementAction == "p" {
                    guard let image else { throw GraphicsFailure("ENOENT") }
                    let width =
                        Int(effective["c"] ?? "")
                        ?? (image.width + (configuration.cellPixelWidth > 0 ? configuration.cellPixelWidth : 8) - 1)
                        / (configuration.cellPixelWidth > 0 ? configuration.cellPixelWidth : 8)
                    let height =
                        Int(effective["r"] ?? "")
                        ?? (image.height + (configuration.cellPixelHeight > 0 ? configuration.cellPixelHeight : 16) - 1)
                        / (configuration.cellPixelHeight > 0 ? configuration.cellPixelHeight : 16)
                    let placement = InlinePlacement(
                        imageID: image.id, placementID: UInt32(effective["p"] ?? "0") ?? 0,
                        line: linesScrolledOff + UInt64(cursor.y), column: cursor.x, columns: width, rows: height,
                        alternate: isAlternateScreen, zIndex: Int32(effective["z"] ?? "0") ?? 0)
                    try inlineGraphics.place(placement)
                    if effective["C"] != "1" { for _ in 0..<height { execute(10) }; execute(13) }
                }
            }
            _ = clock.tick()
        } catch let error as GraphicsFailure { response = error.message } catch { response = "EINVAL" }
        if quiet < 2 && (quiet == 0 || response != "OK") {
            replies += Array("\u{1B}_Gi=\(responseID);\(response)\u{1B}\\".utf8)
        }
    }
}
