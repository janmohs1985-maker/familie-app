import SwiftUI
import WebRTC

// Live-Bild der Kameras über WebRTC (unter 1 s Verzögerung statt 10–15 s bei HLS).
// Vermittlung über die HA-WebSocket-API (camera/webrtc/offer, …/candidate), HAs eingebautes go2rtc
// liefert das Bild. Unterwegs helfen die ICE-Server aus camera/webrtc/get_client_config (Nabu Casa).

@MainActor
final class LiveRTC: NSObject {
    enum State { case idle, connecting, playing, failed }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    /// Alle Anzeigen, die das Bild gerade zeigen (Kachel und Vollbild)
    private var renderers: [RTCMTLVideoView] = []

    func attach(_ v: RTCMTLVideoView) {
        guard !renderers.contains(v) else { return }
        renderers.append(v)
        track?.add(v)
    }
    func detach(_ v: RTCMTLVideoView) {
        track?.remove(v)
        renderers.removeAll { $0 === v }
    }

    private(set) var state: State = .idle { didSet { onState?(state) } }
    var onState: ((State) -> Void)?

    private var pc: RTCPeerConnection?
    private var track: RTCVideoTrack?
    private var ws: URLSessionWebSocketTask?
    private var entityID = ""
    private var sessionID: String?
    private var pending: [RTCIceCandidate] = []
    private var nextID = 3
    private var reader: Task<Void, Never>?

    /// Verbindung aufbauen; true, sobald das erste Bild läuft (oder false nach Zeitüberschreitung)
    func start(_ store: AppStore, entityID: String, timeout: TimeInterval = 8) async -> Bool {
        stop()
        self.entityID = entityID
        state = .connecting
        guard let req = try? await store.client.authorizedRequest(path: "api/websocket"),
              let url = req.url?.absoluteURL,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = req.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        else { state = .failed; return false }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        let task = URLSession.shared.webSocketTask(with: comps.url!)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        ws = task

        do {
            _ = try await receive()                                   // auth_required
            try await send(["type": "auth", "access_token": token])
            guard try await receive()["type"]?.string == "auth_ok" else { throw HAError.http(401, "") }

            // ICE-Server (STUN/TURN) von HA
            try await send(["id": 1, "type": "camera/webrtc/get_client_config", "entity_id": entityID])
            var iceServers: [RTCIceServer] = []
            while true {
                let r = try await receive()
                guard r["id"]?.int == 1 else { continue }
                for s in r["result"]?["configuration"]?["iceServers"]?.array ?? [] {
                    let urls = s["urls"]?.array?.compactMap(\.string) ?? s["urls"]?.string.map { [$0] } ?? []
                    guard !urls.isEmpty else { continue }
                    iceServers.append(RTCIceServer(urlStrings: urls, username: s["username"]?.string,
                                                   credential: s["credential"]?.string))
                }
                break
            }

            let config = RTCConfiguration()
            config.iceServers = iceServers
            config.sdpSemantics = .unifiedPlan
            config.continualGatheringPolicy = .gatherContinually
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
                throw HAError.unexpected("WebRTC nicht verfügbar")
            }
            self.pc = pc
            let init_ = RTCRtpTransceiverInit()
            init_.direction = .recvOnly
            if let tr = pc.addTransceiver(of: .video, init: init_), let t = tr.receiver.track as? RTCVideoTrack {
                track = t
                for v in renderers { t.add(v) }
            }

            let offer = try await pc.offer(for: RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "false"], optionalConstraints: nil))
            try await pc.setLocalDescription(offer)
            try await send(["id": 2, "type": "camera/webrtc/offer", "entity_id": entityID, "offer": offer.sdp])

            reader = Task { [weak self] in await self?.readLoop() }
        } catch {
            stop()
            state = .failed
            return false
        }

        // Warten, bis das Bild läuft
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, state == .connecting {
            try? await Task.sleep(for: .milliseconds(150))
        }
        if state != .playing { stop(); state = .failed; return false }
        return true
    }

    func stop() {
        reader?.cancel()
        reader = nil
        if let track { for v in renderers { track.remove(v) } }
        track = nil
        pc?.close()
        pc = nil
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        sessionID = nil
        pending = []
        if state != .failed { state = .idle }
    }

    // MARK: Vermittlung

    private func readLoop() async {
        while !Task.isCancelled, ws != nil {
            guard let msg = try? await receive() else {
                if state == .connecting { state = .failed }
                return
            }
            guard msg["id"]?.int == 2 else { continue }
            if msg["type"]?.string == "result", msg["success"]?.string == "false" { state = .failed; return }
            guard msg["type"]?.string == "event", let ev = msg["event"] else { continue }
            switch ev["type"]?.string {
            case "session":
                sessionID = ev["session_id"]?.string
                let list = pending
                pending = []
                for c in list { await sendCandidate(c) }
            case "answer":
                if let sdp = ev["answer"]?.string {
                    try? await pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                }
            case "candidate":
                let c = ev["candidate"]
                if let s = c?["candidate"]?.string ?? c?.string, !s.isEmpty {
                    let cand = RTCIceCandidate(sdp: s, sdpMLineIndex: Int32(c?["sdpMLineIndex"]?.int ?? 0),
                                               sdpMid: c?["sdpMid"]?.string ?? "0")
                    try? await pc?.add(cand)
                }
            case "error":
                state = .failed
                return
            default: break
            }
        }
    }

    private func sendCandidate(_ c: RTCIceCandidate) async {
        guard let sessionID else { pending.append(c); return }
        let id = nextID
        nextID += 1
        try? await send(["id": id, "type": "camera/webrtc/candidate", "entity_id": entityID, "session_id": sessionID,
                         "candidate": ["candidate": c.sdp, "sdpMid": c.sdpMid ?? "0", "sdpMLineIndex": Int(c.sdpMLineIndex)]])
    }

    private func receive() async throws -> JSONValue {
        guard let ws else { throw HAError.notConfigured }
        switch try await ws.receive() {
        case .string(let s): return try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
        case .data(let d): return try JSONDecoder().decode(JSONValue.self, from: d)
        @unknown default: throw HAError.unexpected("Unbekannte Antwort vom Server.")
        }
    }

    private func send(_ obj: [String: Any]) async throws {
        guard let ws else { throw HAError.notConfigured }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

extension LiveRTC: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in await self.sendCandidate(candidate) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected: if self.state == .connecting { self.state = .playing }
            case .failed: self.state = .failed
            default: break
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Zeigt das WebRTC-Bild in SwiftUI
struct RTCVideoView: UIViewRepresentable {
    let rtc: LiveRTC
    var fill = true

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.backgroundColor = .black
        v.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        rtc.attach(v)
        context.coordinator.view = v
        return v
    }
    func updateUIView(_ v: RTCMTLVideoView, context: Context) {
        v.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        rtc.attach(v)
    }
    static func dismantleUIView(_ v: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.rtc.detach(v)
    }
    func makeCoordinator() -> Coordinator { Coordinator(rtc: rtc) }

    final class Coordinator {
        let rtc: LiveRTC
        weak var view: RTCMTLVideoView?
        init(rtc: LiveRTC) { self.rtc = rtc }
    }
}
