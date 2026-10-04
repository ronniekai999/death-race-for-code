import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

extension RGB {
    /// WCAG 2 relative luminance: 0 for black, 1 for white.
    public var luminance: Double {
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG 2 contrast ratio between two colors, from 1 (none) to 21 (black on white).
    /// Text needs 4.5 to be readable; icons and lines need 3.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color moved `fraction` of the way to `other`, in sRGB, as CSS mixes.
    public func mixed(with other: RGB, by fraction: Double) -> RGB {
        func channel(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * fraction).rounded())
        }
        return RGB(channel(red, other.red), channel(green, other.green), channel(blue, other.blue))
    }
}
