import Foundation
import Darwin

/// Keeps the renderer, scanners, and notification scheduler owned by one
/// process. A foreground secondary process only asks the primary process to
/// reveal its dashboard, then exits.
final class SingleInstanceCoordinator {
    enum Acquisition {
        case primary(SingleInstanceCoordinator)
        case secondary
    }

    static let showDashboardNotification = Notification.Name("vn.hodinhminh.petrunner.show-dashboard")

    private let lockDescriptor: Int32

    private init(lockDescriptor: Int32) {
        self.lockDescriptor = lockDescriptor
    }

    deinit { close(lockDescriptor) }

    static func acquire() -> Acquisition {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PetRunner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lockURL = support.appendingPathComponent("primary.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return .secondary }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return .secondary
        }
        return .primary(SingleInstanceCoordinator(lockDescriptor: descriptor))
    }

    static func requestDashboard() {
        DistributedNotificationCenter.default().postNotificationName(
            showDashboardNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
