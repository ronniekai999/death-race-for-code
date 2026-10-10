import Foundation
import Testing

@testable import VTCore

@Suite struct InlineGraphicsTests {
    @Test func chunkedRGBPlacementQueriesDeletionAndAlternateScreenLifetime() throws {
        let terminal = Terminal(.init(columns: 20, rows: 5))
        terminal.feed("\u{1B}_Ga=T,f=24,s=2,v=1,i=7,c=2,r=1,C=1,m=1;/wAA\u{1B}\\")
        #expect(terminal.inlineGraphics.images.isEmpty)
        terminal.feed("\u{1B}_Gm=0;AP8A\u{1B}\\")
        #expect(terminal.inlineGraphics.images[7]?.bytes == [255, 0, 0, 0, 255, 0])
        #expect(terminal.inlineGraphics.placements.count == 1)
        #expect(String(decoding: terminal.takeReplies(), as: UTF8.self).contains("i=7;OK"))
        terminal.feed("\u{1B}[?1049h\u{1B}_Ga=p,i=7,p=2,c=2,r=1,C=1;\u{1B}\\")
        #expect(terminal.inlineGraphics.placements.count == 2)
        terminal.feed("\u{1B}[?1049l")
        #expect(terminal.inlineGraphics.placements.count == 1)
        terminal.feed("\u{1B}_Ga=d,d=I,i=7;\u{1B}\\")
        #expect(terminal.inlineGraphics.images.isEmpty)
        #expect(terminal.inlineGraphics.placements.isEmpty)
    }

    @Test func malformedOversizedAndFilesystemTransmissionsAreRefused() {
        let terminal = Terminal()
        terminal.feed("\u{1B}_Ga=T,t=f,f=24,s=1,v=1,i=1;L2V0Yy9wYXNzd2Q=\u{1B}\\")
        terminal.feed("\u{1B}_Ga=T,f=32,s=999999999,v=999999999,i=2;AAAAAA==\u{1B}\\")
        terminal.feed("\u{1B}_Ga=T,f=32,s=1,v=1,i=3;???\u{1B}\\")
        #expect(terminal.inlineGraphics.images.isEmpty)
        #expect(terminal.inlineGraphics.placements.isEmpty)
        #expect(String(decoding: terminal.takeReplies(), as: UTF8.self).contains("EINVAL"))
        terminal.feed("\u{1B}_Ga=q,f=24,s=1,v=1,i=4;AAAA\u{1B}\\")
        #expect(String(decoding: terminal.takeReplies(), as: UTF8.self).contains("i=4;OK"))
        #expect(terminal.inlineGraphics.images.isEmpty)
    }

    @Test func cachesAreBoundedAndResetReleasesThem() {
        let terminal = Terminal()
        for id in 1...40 { terminal.feed("\u{1B}_Ga=T,f=24,s=1,v=1,i=\(id),C=1,q=2;AAAA\u{1B}\\") }
        #expect(terminal.inlineGraphics.images.count == InlineGraphics.maximumImages)
        #expect(terminal.inlineGraphics.images[1] == nil)
        terminal.resize(columns: 100, rows: 30)
        #expect(terminal.inlineGraphics.placements.count == InlineGraphics.maximumImages)
        terminal.feed("\u{1B}c")
        #expect(terminal.inlineGraphics.images.isEmpty)
        #expect(terminal.inlineGraphics.placements.isEmpty)
    }

    @Test func resetAndReusedIDsNeverReuseATextureRevision() throws {
        let terminal = Terminal()
        terminal.feed("\u{1B}_Ga=T,f=24,s=1,v=1,i=7,C=1;/wAA\u{1B}\\")
        let first = try #require(terminal.inlineGraphics.images[7])
        terminal.feed("\u{1B}c\u{1B}_Ga=T,f=24,s=1,v=1,i=7,C=1;AP8A\u{1B}\\")
        let second = try #require(terminal.inlineGraphics.images[7])
        #expect(first.revision != second.revision)
        #expect(second.bytes == [0, 255, 0])
    }
}
