import SwiftUI
import UIKit

// MARK: - Geräte der Familie
//
// Jede App meldet sich beim Öffnen bei Family Hub (rest_command.familie_geraet_set):
// wer, welches iPhone, iOS- und App-Version. Die Liste steht in den Einstellungen (nur Jan).

struct FamilyDevice: Identifiable, Hashable {
    let id: String
    let person: String
    let kid: String
    let model: String
    let ios: String
    let version: String
    let build: Int
    let lastSeen: Date
    let firstSeen: Date?
}

struct FamilyDevicesInfo {
    var devices: [FamilyDevice]
    var currentVersion: String?
    var currentBuild: Int?
    var profileDevices: Int?
    var serverNow: Date
}

enum DeviceReport {
    /// zuletzt gemeldet (nicht öfter als alle 5 Minuten)
    @MainActor static var last: Date?

    @MainActor static var deviceID: String { UIDevice.current.identifierForVendor?.uuidString ?? "unbekannt-geraet" }

    @MainActor static var modelName: String {
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return models[id] ?? (id.hasPrefix("iPad") ? "iPad" : id.hasPrefix("iPhone") ? "iPhone (\(id))" : id)
    }

    static let models: [String: String] = [
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3. Gen.)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air",
        "x86_64": "Simulator", "arm64": "Simulator",
    ]
}

@MainActor
extension AppStore {
    /// Name der angemeldeten Person (Jan, Vanessa, Emma, Leoni)
    var currentPersonName: String? {
        guard let uid = currentUserID, !uid.isEmpty else { return nil }
        return FamilyConfig.people.first { states[$0.id]?.attr("user_id")?.string == uid }?.name
    }

    /// Diese App bei Family Hub melden – still im Hintergrund, Fehler egal
    func reportDevice(force: Bool = false) async {
        guard isLoggedIn else { return }
        if !force, let l = DeviceReport.last, Date().timeIntervalSince(l) < 300 { return }
        if currentUserID == nil { await loadCurrentUser() }
        let cur = AppVersionInfo.current
        var data: [String: Any] = [
            "id": DeviceReport.deviceID,
            "modell": DeviceReport.modelName,
            "ios": UIDevice.current.systemVersion,
            "version": cur.version,
            "build": String(cur.build),
            "user_id": currentUserID ?? "",
            "person": currentPersonName ?? "",
        ]
        if let k = detectedKid { data["kind"] = k }
        do {
            try await client.call("rest_command", "familie_geraet_set", ["daten": data])
            DeviceReport.last = Date()
        } catch {
            // nicht melden – ist nur Statistik
        }
    }

    func loadFamilyDevices() async -> FamilyDevicesInfo? {
        guard let r = try? await client.callWithResponse("script", "familie_geraete", [:], timeout: 30) else { return nil }
        let c = r["content"] ?? r
        guard c["ok"]?.string == "true" else { return nil }
        let list: [FamilyDevice] = (c["geraete"]?.array ?? []).compactMap { g in
            guard let id = g["id"]?.string, let last = g["zuletzt"]?.double else { return nil }
            return FamilyDevice(
                id: id,
                person: g["person"]?.string ?? "",
                kid: g["kind"]?.string ?? "",
                model: g["modell"]?.string ?? "iPhone",
                ios: g["ios"]?.string ?? "",
                version: g["version"]?.string ?? "",
                build: Int(g["build"]?.string ?? "") ?? 0,
                lastSeen: Date(timeIntervalSince1970: last),
                firstSeen: g["erstmals"]?.double.map { Date(timeIntervalSince1970: $0) })
        }
        return FamilyDevicesInfo(
            devices: list,
            currentVersion: c["aktuell"]?["version"]?.string,
            currentBuild: Int(c["aktuell"]?["build"]?.string ?? ""),
            profileDevices: c["profil_geraete"]?.int,
            serverNow: c["jetzt"]?.double.map { Date(timeIntervalSince1970: $0) } ?? Date())
    }

    func forgetFamilyDevice(_ id: String) async {
        do { try await client.call("rest_command", "familie_geraet_set", ["daten": ["id": id, "aktion": "loeschen"]]) }
        catch { report(error) }
    }
}

// MARK: - Ansicht

struct FamilyDevicesView: View {
    @Environment(AppStore.self) private var store
    @State private var info: FamilyDevicesInfo?
    @State private var loading = true

    var body: some View {
        List {
            if let info {
                Section { summary(info) }
                devicesSection(info)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Label("Family Hub antwortet gerade nicht", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Geräte der Familie")
        .refreshable { await load() }
        .task {
            await store.reportDevice(force: true)
            await load()
        }
    }

    private func devicesSection(_ info: FamilyDevicesInfo) -> some View {
        let thisID: String = DeviceReport.deviceID
        return Section {
            if info.devices.isEmpty {
                Text("Noch hat sich kein Gerät gemeldet. Jede App meldet sich beim nächsten Öffnen.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(info.devices) { (d: FamilyDevice) in
                FamilyDeviceRow(device: d, info: info, isThis: d.id == thisID)
                    .swipeActions { forgetButton(d) }
            }
        } header: {
            Text("iPhones mit der App")
        } footer: {
            Text("Jede App meldet sich beim Öffnen – höchstens alle 5 Minuten. Alte Geräte nach links wischen zum Entfernen.")
        }
    }

    private func forgetButton(_ d: FamilyDevice) -> some View {
        Button(role: .destructive) {
            Task { await store.forgetFamilyDevice(d.id); await load() }
        } label: {
            Label("Vergessen", systemImage: "trash")
        }
    }

    private func load() async {
        loading = true
        info = await store.loadFamilyDevices()
        loading = false
    }

    private func summary(_ info: FamilyDevicesInfo) -> some View {
        let newest: Int = info.currentBuild ?? 0
        let now: Date = info.serverNow
        let current: Int = info.devices.filter { (d: FamilyDevice) -> Bool in d.build >= newest }.count
        let active: Int = info.devices.filter { (d: FamilyDevice) -> Bool in now.timeIntervalSince(d.lastSeen) < 600 }.count
        let allCurrent: Bool = current == info.devices.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                stat("\(info.devices.count)", "Geräte", Color.indigo)
                stat("\(active)", "gerade aktiv", Color.green)
                stat("\(current)", "aktuell", allCurrent ? Color.green : Color.orange)
            }
            if let v = info.currentVersion, let b = info.currentBuild {
                Label("Neueste Version: \(v) (\(b))", systemImage: "arrow.down.app")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let n = info.profileDevices {
                let who: String = n == 1 ? "1 iPhone darf" : "\(n) iPhones dürfen"
                Label(who + " die App installieren (bei Apple eingetragen)", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FamilyDeviceRow: View {
    @Environment(AppStore.self) private var store
    let device: FamilyDevice
    let info: FamilyDevicesInfo
    let isThis: Bool

    private var person: FamilyConfig.Person? { FamilyConfig.people.first { $0.name == device.person } }
    private var age: TimeInterval { info.serverNow.timeIntervalSince(device.lastSeen) }
    private var online: Bool { age < 600 }
    private var outdated: Bool { info.currentBuild.map { device.build < $0 } ?? false }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let p = person {
                    Avatar(image: store.pictures[p.id], name: p.name, color: p.color, initialFont: .headline, ring: 0)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "iphone")
                        .font(.title3).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                Circle()
                    .fill(online ? Color.green : Color(.systemGray3))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.person.isEmpty ? "Unbekannt" : device.person).font(.subheadline.weight(.semibold))
                    if isThis {
                        Text("dieses iPhone").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("\(device.model) · iOS \(device.ios)").font(.caption).foregroundStyle(.secondary)
                Text(lastSeenText).font(.caption2).foregroundStyle(online ? Color.green : Color.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(device.version).font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(outdated ? Color.orange : Color.primary)
                Text(outdated ? "Update fehlt" : "aktuell")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(outdated ? Color.orange : Color.green)
                    .background((outdated ? Color.orange : Color.green).opacity(0.14), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private var lastSeenText: String {
        if age < 600 { return "gerade aktiv" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.unitsStyle = .full
        return "zuletzt " + f.localizedString(for: device.lastSeen, relativeTo: info.serverNow)
    }
}
