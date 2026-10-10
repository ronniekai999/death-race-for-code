import Testing
import VTCore

@testable import ScreenProtocol

@Suite struct InlineGraphicsDeltaTests {
    @Test func resetReplacesAssetsEvenWhenTheSameIDAndPlacementCountAreReused() throws {
        let terminal = Terminal()
        var builder = DeltaBuilder()
        var mirror = MirrorGrid()
        terminal.feed("\u{1B}_Ga=T,f=24,s=1,v=1,i=7,C=1;/wAA\u{1B}\\")
        let before = builder.makeDelta(from: terminal, events: [])
        try mirror.apply(before)
        builder.didDeliver(before)
        terminal.feed("\u{1B}c\u{1B}_Ga=T,f=24,s=1,v=1,i=7,C=1;AP8A\u{1B}\\")
        let after = builder.makeDelta(from: terminal, events: [])
        #expect(after.graphicsRevision != before.graphicsRevision)
        #expect(after.images?.first?.bytes == [0, 255, 0])
        try mirror.apply(DeltaCodec.decode(DeltaCodec.encode(after)))
        #expect(mirror.images[7]?.bytes == [0, 255, 0])
    }

    @Test func assetsCrossTheWireOnceAndReattachAndScrollKeepPlacements() throws {
        let terminal = Terminal(.init(columns: 10, rows: 3))
        terminal.feed("\u{1B}_Ga=T,f=24,s=1,v=1,i=1,c=2,r=2,C=1;AAAA\u{1B}\\")
        var builder = DeltaBuilder()
        var mirror = MirrorGrid()
        let first = builder.makeDelta(from: terminal, events: [])
        let encoded = DeltaCodec.encode(first)
        #expect(try DeltaCodec.decode(encoded) == first)
        try mirror.apply(first)
        builder.didDeliver(first)
        terminal.feed("hello")
        let second = builder.makeDelta(from: terminal, events: [])
        #expect(second.images == nil)
        try mirror.apply(DeltaCodec.decode(DeltaCodec.encode(second)))
        #expect(mirror.images[1]?.bytes == [0, 0, 0])
        terminal.feed("\r\nnext\r\nlast\r\nnew")
        builder.scroll(by: 2, in: terminal)
        let scrolled = builder.makeDelta(from: terminal, events: [])
        #expect(scrolled.placements.first?.line == 0)
        var reattached = MirrorGrid()
        builder.reset()
        try reattached.apply(DeltaCodec.decode(DeltaCodec.encode(builder.makeDelta(from: terminal, events: []))))
        #expect(reattached.images[1] != nil)
        for length in 0..<encoded.count {
            #expect(throws: DeltaCodec.DecodeError.self) { try DeltaCodec.decode(Array(encoded.prefix(length))) }
        }
    }
}
