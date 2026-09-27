import SwiftUI

// MARK: - Gäste-WLAN (UniFi)
//
// Das Scanner-Add-on spricht mit dem API-Schlüssel aus seiner Konfiguration direkt mit der UDM-Pro.
// Die App sieht den Schlüssel nie – sie ruft nur script.familie_scanner (aktion: guests / guest_action) auf.
// Nur für Eltern.

struct GuestClient: Identifiable, Hashable {
    let mac: String
    let name: String
    let hostname: String
    let ip: String
    let vendor: String
    let uptime: Int
    var id: String { mac }

    init(_ j: JSONValue) {
        mac = j["mac"]?.string ?? ""
        name = j["name"]?.string ?? mac
        hostname = j["hostname"]?.string ?? ""
        ip = j["ip"]?.string ?? ""
        vendor = j["vendor"]?.string ?? ""
        uptime = j["uptime"]?.int ?? 0
    }

    var uptimeText: String {
        guard uptime > 0 else { return "" }
        let h = uptime / 3600, m = (uptime % 3600) / 60
        return h > 0 ? "seit \(h) Std. \(m) Min." : "seit \(max(m, 1)) Min."
    }

    var details: String {
        [ip, vendor, uptimeText].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

@MainActor
extension AppStore {

    var canManageNetwork: Bool { isParent && activeKid == nil }

    /// (online, gesperrt)
    func loadGuests() async throws -> ([GuestClient], [GuestClient]) {
        let r = try await client.callWithResponse("script", FamilyConfig.scannerScript, ["aktion": "guests"], timeout: 30)
        guard r["ok"]?.string == "true" else {
            throw ScannerError(message: r["error"]?.string ?? "Gäste-WLAN konnte nicht geladen werden.")
        }
        return ((r["online"]?.array ?? []).map(GuestClient.init), (r["blocked"]?.array ?? []).map(GuestClient.init))
    }

    func guestAction(_ action: String, mac: String) async throws {
        let r = try await client.callWithResponse("script", FamilyConfig.scannerScript,
                                                  ["aktion": "guest_action", "mac": mac, "action": action], timeout: 30)
        guard r["ok"]?.string == "true" else {
            throw ScannerError(message: r["error"]?.string ?? "Aktion fehlgeschlagen.")
        }
    }

    /// Passwort der Gäste-Anmeldeseite (UniFi Hotspot / Captive Portal)
    func loadGuestPassword() async throws -> String {
        let r = try await client.callWithResponse("script", FamilyConfig.scannerScript, ["aktion": "wifi"], timeout: 30)
        guard r["ok"]?.string == "true" else {
            throw ScannerError(message: r["error"]?.string ?? "Passwort konnte nicht geladen werden.")
        }
        return r["password"]?.string ?? ""
    }

    func setGuestPassword(_ pw: String) async throws {
        let r = try await client.callWithResponse("script", FamilyConfig.scannerScript,
                                                  ["aktion": "wifi_password", "password": pw], timeout: 30)
        guard r["ok"]?.string == "true" else {
            throw ScannerError(message: r["error"]?.string ?? "Passwort konnte nicht geändert werden.")
        }
    }

    func setGuestWifi(_ on: Bool) async {
        do {
            try await client.call("switch", on ? "turn_on" : "turn_off", ["entity_id": FamilyConfig.guestWifiSwitch])
            try? await Task.sleep(for: .seconds(1))
            await refreshStates()
        } catch { report(error) }
    }
}

struct GuestWifiView: View {
    @Environment(AppStore.self) private var store
    @State private var online: [GuestClient] = []
    @State private var blocked: [GuestClient] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var busy: Set<String> = []
    @State private var confirmBlock: GuestClient?
    @State private var confirmWifiOff = false
    @State private var password: String?
    @State private var showPassword = false
    @State private var changing = false
    @State private var newPassword = ""
    @State private var pwMessage: String?

    private var wifiOn: Bool { store.states[FamilyConfig.guestWifiSwitch]?.state == "on" }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { wifiOn }, set: { on in
                    if on { Task { await store.setGuestWifi(true) } } else { confirmWifiOff = true }
                })) {
                    Label("Gäste-WLAN", systemImage: "wifi")
                }
            } footer: {
                Text("Schaltet das WLAN „Mohs - Gäste“ komplett ein oder aus.")
            }

            Section {
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.orange).frame(width: 30)
                    if let password {
                        Text(showPassword ? password : String(repeating: "•", count: max(password.count, 6)))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    } else {
                        ProgressView()
                    }
                    Spacer()
                    if password != nil {
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            UIPasteboard.general.string = password
                            pwMessage = "Kopiert."
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Passwort ändern …") { newPassword = ""; changing = true }
                    .disabled(password == nil)
            } header: {
                Text("Passwort der Anmeldeseite")
            } footer: {
                Text(pwMessage ?? "Das geben Gäste auf der UniFi-Anmeldeseite ein, nachdem sie sich mit „Mohs - Gäste“ verbunden haben.")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
            }

            Section {
                if !loaded {
                    HStack { ProgressView(); Text("Lade …").foregroundStyle(.secondary) }
                } else if online.isEmpty {
                    Text("Gerade ist niemand im Gäste-WLAN.").foregroundStyle(.secondary)
                }
                ForEach(online) { c in
                    ClientRow(client: c, busy: busy.contains(c.mac))
                        .swipeActions(edge: .trailing) {
                            Button("Sperren", role: .destructive) { confirmBlock = c }
                            Button("Trennen") { run("kick", c) }.tint(.orange)
                        }
                        .contextMenu {
                            Button { run("kick", c) } label: { Label("Trennen", systemImage: "wifi.slash") }
                            Button(role: .destructive) { confirmBlock = c } label: { Label("Sperren", systemImage: "hand.raised.fill") }
                        }
                }
            } header: {
                Text(loaded ? "Verbunden (\(online.count))" : "Verbunden")
            } footer: {
                Text("Nach links wischen: „Trennen“ wirft das Gerät raus (es kann sich wieder verbinden), „Sperren“ lässt es gar nicht mehr ins WLAN.")
            }

            if !blocked.isEmpty {
                Section("Gesperrt (\(blocked.count))") {
                    ForEach(blocked) { c in
                        ClientRow(client: c, busy: busy.contains(c.mac), blocked: true)
                            .swipeActions(edge: .trailing) {
                                Button("Freigeben") { run("unblock", c) }.tint(.green)
                            }
                            .contextMenu {
                                Button { run("unblock", c) } label: { Label("Freigeben", systemImage: "checkmark.circle") }
                            }
                    }
                }
            }
        }
        .navigationTitle("Gäste-WLAN")
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .confirmationDialog("Gerät sperren?", isPresented: Binding(get: { confirmBlock != nil }, set: { if !$0 { confirmBlock = nil } }),
                            titleVisibility: .visible, presenting: confirmBlock) { c in
            Button("\(c.name) sperren", role: .destructive) { run("block", c) }
        } message: { c in
            Text("\(c.name) wird getrennt und kommt nicht mehr ins WLAN, bis du es unter „Gesperrt“ wieder freigibst.")
        }
        .alert("Neues Passwort", isPresented: $changing) {
            TextField("mind. 4 Zeichen", text: $newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") { savePassword() }
        } message: {
            Text("Gilt für neue Anmeldungen. Bereits verbundene Gäste bleiben online.")
        }
        .task { await loadPassword() }
        .confirmationDialog("Gäste-WLAN ausschalten?", isPresented: $confirmWifiOff, titleVisibility: .visible) {
            Button("Ausschalten", role: .destructive) { Task { await store.setGuestWifi(false) } }
        } message: {
            Text("Alle Gäste verlieren sofort die Verbindung.")
        }
    }

    private func load() async {
        do {
            let r = try await store.loadGuests()
            online = r.0
            blocked = r.1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadPassword() async {
        do { password = try await store.loadGuestPassword() }
        catch { pwMessage = error.localizedDescription }
    }

    private func savePassword() {
        let pw = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await store.setGuestPassword(pw)
                password = pw
                showPassword = true
                pwMessage = "Passwort geändert."
            } catch {
                pwMessage = error.localizedDescription
            }
        }
    }

    private func run(_ action: String, _ c: GuestClient) {
        busy.insert(c.mac)
        Task {
            do {
                try await store.guestAction(action, mac: c.mac)
                try? await Task.sleep(for: .seconds(1))
                await load()
            } catch {
                self.error = error.localizedDescription
            }
            busy.remove(c.mac)
        }
    }
}

struct ClientRow: View {
    let client: GuestClient
    var busy = false
    var blocked = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: blocked ? "hand.raised.fill" : icon)
                .font(.title3)
                .foregroundStyle(blocked ? Color.red : Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).font(.body.weight(.medium)).lineLimit(1)
                Text(blocked ? client.mac : client.details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if busy { ProgressView() }
        }
    }

    private var icon: String {
        let s = (client.name + " " + client.vendor + " " + client.hostname).lowercased()
        if s.contains("iphone") || s.contains("android") || s.contains("galaxy") || s.contains("pixel") { return "iphone" }
        if s.contains("ipad") || s.contains("tab") { return "ipad" }
        if s.contains("macbook") || s.contains("laptop") || s.contains("pc") { return "laptopcomputer" }
        if s.contains("apple") { return "applelogo" }
        return "wifi"
    }
}
