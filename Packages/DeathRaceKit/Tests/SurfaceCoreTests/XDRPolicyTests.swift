import Testing

@testable import SurfaceCore

@Suite struct XDRPolicyTests {
    @Test func optInDisplaySupportAndEnergyDetermineHeadroom() {
        let normal = FrameRatePolicy.Conditions(recentInput: false)
        #expect(XDRPolicy.headroom(requested: false, displayHeadroom: 4, conditions: normal) == 0)
        #expect(XDRPolicy.headroom(requested: true, displayHeadroom: 1, conditions: normal) == 0)
        #expect(XDRPolicy.headroom(requested: true, displayHeadroom: .nan, conditions: normal) == 0)
        #expect(XDRPolicy.headroom(requested: true, displayHeadroom: 4, conditions: normal) == 2)
        #expect(
            XDRPolicy.headroom(
                requested: true, displayHeadroom: 2,
                conditions: .init(recentInput: true, lowPowerMode: true)) == 0)
        #expect(
            XDRPolicy.headroom(
                requested: true, displayHeadroom: 2,
                conditions: .init(recentInput: true, thermal: .serious)) == 0)
    }
}
