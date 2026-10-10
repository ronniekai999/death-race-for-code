import VTCore

extension ByteWriter {
    mutating func graphics(_ delta: ScreenDelta) {
        u64(delta.graphicsRevision)
        bool(delta.images != nil)
        if let images = delta.images {
            u32(UInt32(images.count))
            for image in images {
                u32(image.id); u64(image.revision); u32(image.format.rawValue)
                u32(UInt32(image.width)); u32(UInt32(image.height)); u32(UInt32(image.bytes.count))
                bytes.append(contentsOf: image.bytes)
            }
        }
        u32(UInt32(delta.placements.count))
        for p in delta.placements {
            u32(p.imageID); u32(p.placementID); u64(p.line)
            u32(UInt32(p.column)); u32(UInt32(p.columns)); u32(UInt32(p.rows))
            bool(p.alternate); u32(UInt32(bitPattern: p.zIndex))
        }
    }
}

extension ByteReader {
    mutating func graphics() throws(DeltaCodec.DecodeError) -> (UInt64, [InlineImage]?, [InlinePlacement]) {
        let revision = try u64()
        var images: [InlineImage]?
        if try bool() {
            let n = try count(elementSize: 28)
            guard n <= InlineGraphics.maximumImages else { throw .invalid("too many inline images") }
            var assets: [InlineImage] = []
            var ids: Set<UInt32> = []
            var bytesLeft = InlineImage.maximumBytes
            var pixelsLeft = InlineImage.maximumPixels
            for _ in 0..<n {
                let id = try u32()
                let version = try u64()
                guard let format = InlineImage.Format(rawValue: try u32()) else { throw .invalid("image format") }
                let width = Int(try u32()), height = Int(try u32())
                guard width > 0, height > 0, width <= 4096, height <= 4096, width * height <= pixelsLeft else {
                    throw .invalid("inline image dimensions")
                }
                let size = try count(elementSize: 1)
                guard size <= bytesLeft else { throw .invalid("inline image byte budget") }
                let image = InlineImage(
                    id: id, revision: version, format: format, width: width, height: height, bytes: try take(size))
                guard image.isValid, ids.insert(id).inserted else {
                    throw .invalid("invalid or duplicate inline image")
                }
                bytesLeft -= size; pixelsLeft -= width * height
                assets.append(image)
            }
            images = assets
        }
        let n = try count(elementSize: 33)
        guard n <= InlineGraphics.maximumPlacements else { throw .invalid("too many image placements") }
        var placements: [InlinePlacement] = []
        var keys: Set<UInt64> = []
        for _ in 0..<n {
            let image = try u32(), placement = try u32(), line = try u64()
            let column = Int(try u32()), columns = Int(try u32()), rows = Int(try u32())
            let alternate = try bool(), zIndex = Int32(bitPattern: try u32())
            let p = InlinePlacement(
                imageID: image, placementID: placement, line: line, column: column,
                columns: columns, rows: rows, alternate: alternate, zIndex: zIndex)
            guard p.isValid, keys.insert(p.key).inserted else { throw .invalid("invalid or duplicate image placement") }
            placements.append(p)
        }
        return (revision, images, placements)
    }
}
