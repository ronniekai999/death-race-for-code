/// How many cells a character occupies, and the properties that decide whether it joins the
/// character before it. Tables come from `UnicodeTables` (generated from the UCD).
public enum CharacterWidth {
    /// 0 for characters that combine with the previous one, 2 for wide ones, else 1.
    @inline(__always)
    public static func of(_ scalar: UInt32) -> Int {
        // Latin, Greek, Cyrillic below the combining diacriticals are all width 1.
        if scalar < 0x300 { return scalar >= 0x20 && (scalar < 0x7F || scalar >= 0xA0) ? 1 : 0 }
        if contains(UnicodeTables.zeroWidth, scalar) { return 0 }
        if scalar >= 0x1100 && contains(UnicodeTables.doubleWidth, scalar) { return 2 }
        return 1
    }

    static let zeroWidthJoiner: UInt32 = 0x200D
    static let variationSelector15: UInt32 = 0xFE0E
    static let variationSelector16: UInt32 = 0xFE0F

    @inline(__always)
    static func isRegionalIndicator(_ scalar: UInt32) -> Bool {
        scalar >= 0x1F1E6 && scalar <= 0x1F1FF
    }

    static func isExtendedPictographic(_ scalar: UInt32) -> Bool {
        scalar >= 0xA9 && contains(UnicodeTables.extendedPictographic, scalar)
    }

    static func isEmojiModifier(_ scalar: UInt32) -> Bool {
        scalar >= 0x1F3FB && scalar <= 0x1F3FF
    }

    static func isGraphemeExtend(_ scalar: UInt32) -> Bool {
        scalar >= 0x300 && contains(UnicodeTables.graphemeExtend, scalar)
    }

    /// Binary search over sorted, non-overlapping ranges.
    @inline(__always)
    static func contains(_ ranges: [ClosedRange<UInt32>], _ scalar: UInt32) -> Bool {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) >> 1
            let range = ranges[mid]
            if scalar < range.lowerBound {
                high = mid - 1
            } else if scalar > range.upperBound {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}
