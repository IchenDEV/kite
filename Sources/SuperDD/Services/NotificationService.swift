import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private var notifiedGIDs = Set<String>()

    func requestAuthorizationIfNeeded(enabled: Bool) async {
        guard enabled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func process(tasks: [DownloadTask], enabled: Bool) async {
        guard enabled else { return }
        for task in tasks where task.status == .complete || task.status == .error {
            guard notifiedGIDs.insert(task.gid).inserted else { continue }
            let content = UNMutableNotificationContent()
            if task.status == .complete {
                content.title = "Download Complete"
                content.body = task.name
                content.sound = .default
            } else {
                content.title = "Download Failed"
                content.body = task.errorMessage.map { "\(task.name): \($0)" } ?? task.name
            }
            content.categoryIdentifier = "DOWNLOAD"
            let request = UNNotificationRequest(identifier: task.gid, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func forget(gid: String) {
        notifiedGIDs.remove(gid)
    }
}
