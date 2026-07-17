@testable import PetRunnerCore
import Testing

struct AutonomyTests {
    @Test func configurationValidatesBoundsAndNormalizesEnabledActionWeights() {
        let defaultConfiguration = AutonomyConfiguration.default
        #expect(defaultConfiguration.minimumWait == 10)
        #expect(defaultConfiguration.maximumWait == 20)
        #expect(defaultConfiguration.enabledActions == Set(AutonomousActionKind.allCases))
        #expect(AutonomyConfiguration(minimumWait: 4, maximumWait: 20, enabledActions: [.walk]) == nil)
        #expect(AutonomyConfiguration(minimumWait: 10, maximumWait: 31, enabledActions: [.walk]) == nil)
        #expect(AutonomyConfiguration(minimumWait: 20, maximumWait: 10, enabledActions: [.walk]) == nil)
        #expect(AutonomyConfiguration(minimumWait: 10, maximumWait: 20, enabledActions: []) == nil)

        let configuration = AutonomyConfiguration(minimumWait: 10, maximumWait: 10, enabledActions: [.walk, .cry])!
        var units = [0, 0.8, 0].makeIterator()
        var policy = AutonomyPolicy(configuration: configuration, randomUnit: { units.next() ?? 0 })
        #expect(policy.tick(now: 0, isEligible: true) == nil)
        #expect(policy.tick(now: 10, isEligible: true) == .cry)
    }

    @Test func schedulesWithinTheApprovedTenToTwentySecondRange() {
        var policy = AutonomyPolicy(randomUnit: { 0 })
        #expect(policy.tick(now: 100, isEligible: true) == nil)
        #expect(policy.tick(now: 109.999, isEligible: true) == nil)
        #expect(policy.tick(now: 110, isEligible: true) == .walk(duration: 1))

        var maximumPolicy = AutonomyPolicy(randomUnit: { 1 })
        #expect(maximumPolicy.tick(now: 200, isEligible: true) == nil)
        #expect(maximumPolicy.tick(now: 219.999, isEligible: true) == nil)
        #expect(maximumPolicy.tick(now: 220, isEligible: true) == .cry)
    }

    @Test func selectsConfiguredActionsFromTheirWeights() {
        let cases: [(Double, AutonomousAction)] = [
            (0.39, .walk(duration: 1)),
            (0.40, .wave),
            (0.65, .jump),
            (0.90, .cry)
        ]

        for (choice, expected) in cases {
            var units = [0, choice, 0].makeIterator()
            var policy = AutonomyPolicy(randomUnit: { units.next() ?? 0 })
            #expect(policy.tick(now: 0, isEligible: true) == nil)
            #expect(policy.tick(now: 10, isEligible: true) == expected)
        }
    }

    @Test func immediatelyStartsAnActionUsingTheConfiguredWeights() {
        let configuration = AutonomyConfiguration(
            minimumWait: 10,
            maximumWait: 10,
            enabledActions: [.jump]
        )!
        var policy = AutonomyPolicy(configuration: configuration, randomUnit: { 0 })

        #expect(policy.startAction() == .jump)
        #expect(policy.isPerforming)
    }

    @Test func cancellationDiscardsPendingWaitAndIneligibleTicksDoNotStartOne() {
        var policy = AutonomyPolicy(randomUnit: { 0 })
        #expect(policy.tick(now: 0, isEligible: true) == nil)
        policy.cancel()
        #expect(policy.tick(now: 10, isEligible: true) == nil)
        #expect(policy.tick(now: 19.999, isEligible: true) == nil)
        #expect(policy.tick(now: 20, isEligible: true) == .walk(duration: 1))

        #expect(policy.tick(now: 30, isEligible: false) == nil)
        #expect(policy.tick(now: 30, isEligible: true) == nil)
        #expect(policy.tick(now: 40, isEligible: true) == .walk(duration: 1))
    }

    @Test func updatingConfigurationCancelsAnExistingWait() {
        var policy = AutonomyPolicy(randomUnit: { 0 })
        #expect(policy.tick(now: 0, isEligible: true) == nil)
        policy.update(configuration: AutonomyConfiguration(
            minimumWait: 10,
            maximumWait: 10,
            enabledActions: [.wave]
        )!)
        #expect(policy.tick(now: 10, isEligible: true) == nil)
        #expect(policy.tick(now: 20, isEligible: true) == .wave)
    }
}
