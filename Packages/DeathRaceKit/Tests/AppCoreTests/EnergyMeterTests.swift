import Testing

@testable import AppCore

@Suite struct EnergyMeterTests {
    @Test func ratesLeaveOutThePagesOwnWakeup() throws {
        let earlier = EnergySample(time: 10, cpuNanoseconds: 1_000_000_000, wakeups: 100, frames: 50)
        let later = EnergySample(time: 12, cpuNanoseconds: 1_004_000_000, wakeups: 102, frames: 50)
        let rates = try #require(EnergyMeter.rates(from: earlier, to: later))
        #expect(abs(rates.cpuPercent - 0.2) < 1e-9)
        #expect(rates.wakeupsPerSecond == 0.5)
        #expect(rates.framesPerSecond == 0)
        #expect(rates.cpuText == "0.2% CPU")
        #expect(rates.wakeupsText == "0.5 wakeups a second")
        #expect(rates.framesText == "0 frames a second")
    }

    @Test func nothingWhenTimeOrCountersGoBack() {
        let sample = EnergySample(time: 5, cpuNanoseconds: 10, wakeups: 10, frames: 10)
        #expect(EnergyMeter.rates(from: sample, to: sample) == nil)
        var earlier = sample
        earlier.time = 3
        earlier.wakeups = 20
        #expect(EnergyMeter.rates(from: earlier, to: sample) == nil)
    }

    @Test func numbersReadPlainly() {
        #expect(EnergyRates.format(0) == "0")
        #expect(EnergyRates.format(0.04) == "0")
        #expect(EnergyRates.format(0.45) == "0.5")
        #expect(EnergyRates.format(9.94) == "9.9")
        #expect(EnergyRates.format(119.6) == "120")
        #expect(EnergyRates.format(-1) == "0")
    }
}
