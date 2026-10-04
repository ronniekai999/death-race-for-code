import CoreText
import Foundation

/// The fonts Death Race ships: Monaspace Neon and Radon, and Symbols Nerd Font Mono for the
/// icons in Starship and Powerlevel10k prompts. They are registered for this process only,
/// before the first window, so they never show up in other apps' font menus.
public enum FontRegistry {
    /// The families the app ships, as the font picker lists them after SF Mono.
    public static let bundledFamilies = ["Monaspace Neon", "Monaspace Radon"]
    /// The icons' family, which heads every face's fallback list.
    public static let symbolsFamily = "Symbols Nerd Font Mono"

    /// What registering found.
    public struct Report: Sendable, Equatable {
        /// Where the fonts were looked for; nil when there was nowhere to look.
        public var directory: URL?
        /// The files that registered.
        public var registered: [String] = []
        /// The files that did not, and why.
        public var failed: [String] = []
    }

    /// Where the fonts are: `Contents/Resources/Fonts` in the app; for a run from the
    /// repository, `build/fonts`, where `scripts/fetch-fonts.sh` puts them. `DEATHRACE_FONTS`
    /// overrides both.
    public static func directory(
        bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let manager = FileManager.default
        if let path = environment["DEATHRACE_FONTS"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let resources = bundle.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
            manager.fileExists(atPath: resources.path)
        {
            return resources
        }
        // Sources/RenderKit/FontRegistry.swift in Packages/DeathRaceKit: five levels up is the
        // repository. Only a build on this machine finds it, which is all it is for. (Here
        // in the body, #filePath is this file; as a default argument it would be the caller's.)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let fetched = repository.appendingPathComponent("build/fonts", isDirectory: true)
        return manager.fileExists(atPath: fetched.path) ? fetched : nil
    }

    /// The font files in `directory`, in a stable order.
    public static func fontFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted()
            .filter { $0.hasSuffix(".otf") || $0.hasSuffix(".ttf") }
            .map { directory.appendingPathComponent($0) }
    }

    private static let registration = Registration()

    /// Registers the shipped fonts once; later calls return the first report. Missing fonts
    /// are not an error: SF Mono and the system's fallbacks still work.
    @discardableResult
    public static func registerBundledFonts() -> Report {
        registration.run { directory() }
    }

    /// The icons' font, if it registered.
    public static var symbolsDescriptor: CTFontDescriptor? {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: symbolsFamily] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor]
        return matches?.first
    }

    /// Registers once, whichever thread asks first.
    private final class Registration: @unchecked Sendable {
        private let lock = NSLock()
        private var report: Report?

        func run(_ find: () -> URL?) -> Report {
            lock.lock()
            defer { lock.unlock() }
            if let report { return report }
            var result = Report(directory: find())
            for url in result.directory.map(FontRegistry.fontFiles(in:)) ?? [] {
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    result.registered.append(url.lastPathComponent)
                } else {
                    let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
                    result.failed.append("\(url.lastPathComponent): \(reason)")
                }
            }
            report = result
            return result
        }
    }
}
