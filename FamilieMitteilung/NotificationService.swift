import UserNotifications

// Mitteilungs-Erweiterung: lädt das Bild einer Mitteilung (Feld „bild“, z. B. Klingel-Foto) und hängt es an.

final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let best = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content = best
        guard let s = request.content.userInfo["bild"] as? String, let url = URL(string: s) else {
            contentHandler(best)
            return
        }
        let task = URLSession.shared.downloadTask(with: url) { tmp, _, _ in
            if let tmp {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                try? FileManager.default.moveItem(at: tmp, to: dest)
                if let att = try? UNNotificationAttachment(identifier: "bild", url: dest, options: nil) {
                    best.attachments = [att]
                }
            }
            contentHandler(best)
        }
        task.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }
}
