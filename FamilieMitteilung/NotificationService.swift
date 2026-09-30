import UIKit
import Intents
import UserNotifications

// Mitteilungs-Erweiterung:
//  • Feld „bild“   → Foto anhängen (z. B. Klingel)
//  • Feld „symbol“ → farbiges Symbol rechts (Einkauf, Essen, Termine …)
//  • Feld „von“    → Absender mit Profilbild links statt App-Symbol (Mitteilung wie bei iMessage)

final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let best = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content = best
        let info = request.content.userInfo
        let group = DispatchGroup()
        let lock = NSLock()
        var senderImage: Data?

        // 1) Foto oder Symbol
        if let s = info["bild"] as? String, let url = URL(string: s) {
            group.enter()
            URLSession.shared.downloadTask(with: url) { tmp, _, _ in
                if let tmp {
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                    try? FileManager.default.moveItem(at: tmp, to: dest)
                    if let att = try? UNNotificationAttachment(identifier: "bild", url: dest, options: nil) {
                        lock.lock(); best.attachments = [att]; lock.unlock()
                    }
                }
                group.leave()
            }.resume()
        } else if let sym = info["symbol"] as? String, let file = Self.renderSymbol(sym, hex: info["farbe"] as? String),
                  let att = try? UNNotificationAttachment(identifier: "symbol", url: file, options: nil) {
            best.attachments = [att]
        }

        // 2) Profilbild des Absenders
        if let s = info["von_bild"] as? String, let url = URL(string: s) {
            group.enter()
            URLSession.shared.dataTask(with: url) { data, response, _ in
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    lock.lock(); senderImage = data; lock.unlock()
                }
                group.leave()
            }.resume()
        }

        group.notify(queue: .main) {
            lock.lock(); let img = senderImage; lock.unlock()
            if let von = info["von"] as? String, let name = info["von_name"] as? String,
               let updated = Self.communication(best, von: von, name: name, image: img) {
                contentHandler(updated)
            } else {
                contentHandler(best)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }

    /// Mitteilung „von einer Person“ – iOS zeigt dann ihr Bild statt des App-Symbols
    private static func communication(_ content: UNMutableNotificationContent, von: String, name: String,
                                      image: Data?) -> UNNotificationContent? {
        // der eigene Titel bleibt als Untertitel erhalten, oben steht der Name
        if content.subtitle.isEmpty { content.subtitle = content.title }
        let handle = INPersonHandle(value: von, type: .unknown)
        let person = INPerson(personHandle: handle, nameComponents: nil, displayName: name,
                              image: image.map { INImage(imageData: $0) }, contactIdentifier: nil, customIdentifier: von)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: nil, conversationIdentifier: "familie-" + von,
                                         serviceName: nil, sender: person, attachments: nil)
        if let image { intent.setImage(INImage(imageData: image), forParameterNamed: \.sender) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return try? content.updating(from: intent)
    }

    /// Farbiges Quadrat mit weißem Symbol als kleines Bild rechts in der Mitteilung
    private static func renderSymbol(_ name: String, hex: String?) -> URL? {
        let size = CGSize(width: 120, height: 120)
        let color = UIColor(hex: hex ?? "") ?? .systemIndigo
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 28).fill()
            let cfg = UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold)
            if let sym = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let s = sym.size
                sym.draw(in: CGRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height))
            }
        }
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("symbol-\(UUID().uuidString).png")
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
