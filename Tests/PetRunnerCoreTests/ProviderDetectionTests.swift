import PetRunnerCore
import Testing

struct ProviderDetectionTests {
    @Test func reportsOnlyProvidersWithKnownInstallationFootprints() {
        let detected = ProviderDetector.detect(existingPaths: [".claude", ".cursor/hooks.json"])

        #expect(detected.first { $0.provider == .claude }?.isDetected == true)
        #expect(detected.first { $0.provider == .codex }?.isDetected == false)
        #expect(detected.first { $0.provider == .cursor }?.isDetected == true)
    }

    @Test func glyphTableCoversEveryFixedVisibleLabel() {
        for text in AgentProvider.allCases.map(\.displayLabel) + AgentStatus.allCases.map(\.displayText) {
            for character in text.replacingOccurrences(of: "…", with: "...") where character != " " {
                #expect(PixelGlyphs.rows[character.uppercased().first ?? " "] != nil)
            }
        }
    }

    @Test func glyphTableCoversSessionLabelsAndPixelControls() {
        for character in "SESSION 0123456789ABCDEF+-/" where character != " " {
            #expect(PixelGlyphs.rows[character] != nil)
        }
    }
}
