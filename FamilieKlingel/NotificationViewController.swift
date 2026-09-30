import UIKit
import UserNotifications
import UserNotificationsUI

// Ansicht beim langen Drücken auf die Klingel-Mitteilung: Live-Bild der Doorbird (ca. 2 Bilder pro Sekunde).
// Die Knöpfe („Öffnen“, „Sprechen“) kommen von der Mitteilungs-Kategorie KLINGEL der App.

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let imageView = UIImageView()
    private let badge = UILabel()
    private let hint = UILabel()
    private var timer: Timer?
    private var liveURL: URL?
    private var loading = false
    private var failures = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preferredContentSize = CGSize(width: view.bounds.width, height: view.bounds.width * 0.75)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        badge.text = "  ● LIVE  "
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        badge.layer.cornerRadius = 6
        badge.layer.masksToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badge)

        hint.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.textColor = .white
        hint.textAlignment = .center
        hint.numberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 10),
        ])
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        // zuerst das Foto vom Klingeln zeigen
        if let att = content.attachments.first, att.url.startAccessingSecurityScopedResource() {
            if let data = try? Data(contentsOf: att.url) { imageView.image = UIImage(data: data) }
            att.url.stopAccessingSecurityScopedResource()
        }
        if let s = content.userInfo["live"] as? String, let url = URL(string: s) {
            liveURL = url
            startLive()
        } else {
            hint.text = "Foto vom Klingeln"
        }
    }

    private func startLive() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.fetch() }
        fetch()
    }

    private func fetch() {
        guard !loading, let url = liveURL else { return }
        loading = true
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let image = ok ? data.flatMap { UIImage(data: $0) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                if let image {
                    self.failures = 0
                    self.imageView.image = image
                    self.badge.isHidden = false
                    self.hint.text = nil
                } else {
                    self.failures += 1
                    if self.failures >= 3 {
                        self.badge.isHidden = true
                        self.hint.text = "Live-Bild nicht mehr verfügbar – App öffnen"
                        if self.failures >= 10 { self.timer?.invalidate() }
                    }
                }
            }
        }.resume()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
    }
}
