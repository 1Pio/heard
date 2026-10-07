import Testing
@testable import heard

@Test func browserExclusionIncludesAudioHelpersWithoutMatchingOtherApps() {
    if #available(macOS 14.2, *) {
        let excluded: Set<String> = ["net.imput.helium"]
        #expect(CoreAudioTapCapture.isExcluded(bundleIdentifier: "net.imput.helium", identifiers: excluded))
        #expect(CoreAudioTapCapture.isExcluded(bundleIdentifier: "net.imput.helium.helper", identifiers: excluded))
        #expect(CoreAudioTapCapture.isExcluded(bundleIdentifier: "net.imput.helium.helper.renderer", identifiers: excluded))
        #expect(CoreAudioTapCapture.isExcluded(bundleIdentifier: "NET.IMPUT.HELIUM.HELPER", identifiers: excluded))
        #expect(!CoreAudioTapCapture.isExcluded(bundleIdentifier: "net.imput.helium-other", identifiers: excluded))
        #expect(!CoreAudioTapCapture.isExcluded(bundleIdentifier: "us.zoom.caphost", identifiers: excluded))
    }
}
