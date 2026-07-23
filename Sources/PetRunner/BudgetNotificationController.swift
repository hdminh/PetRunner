import Foundation
import UserNotifications
import PetRunnerCore

@MainActor
final class BudgetNotificationController {
    func present(_ alerts: [BudgetEvaluation], petOverride: @escaping (AnimationState?) -> Void) {
        guard !alerts.isEmpty else { return }
        let grouped = Dictionary(grouping: alerts, by: \ .provider)
        for (provider, values) in grouped {
            let highest = values.max { $0.threshold.rawValue < $1.threshold.rawValue }!
            let content = UNMutableNotificationContent()
            content.title = "\(provider.displayName) budget \(highest.threshold == .limit ? "reached" : "nearly reached")"
            content.body = values.map { "\($0.period.capitalized): $\(String(format: "%.2f", $0.spentUSD)) / $\(String(format: "%.2f", $0.limitUSD))" }.joined(separator: " · ")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            petOverride(highest.threshold == .limit ? .failed : .waiting)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { petOverride(nil) }
    }

    func requestPermission() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
}
