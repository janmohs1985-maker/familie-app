import SwiftUI
import AVFoundation

// MARK: - Gespräch mit der Haustür (Doorbird)
//
// Bild und Ton laufen über Home Assistant – zu Hause und unterwegs gleich:
//  • Hören:    GET  /api/familie_tuer/hoeren   (G.711 µ-law, 8 kHz, mono)
//  • Sprechen: POST /api/familie_tuer/sprechen (gleiches Format, als Dauer-Upload)
// Die Erweiterung custom_components/familie_tuer reicht das an die Doorbird durch
// (Sitzung über Family Hub, das Doorbird-Passwort bleibt dort).
// Echounterdrückung wie bei FaceTime (Voice Processing), deshalb freihändig ohne Knopfdrücken.

@MainActor @Observable
final class DoorCall {
    enum Status: Equatable { case idle, connecting, live, onlyVideo(String), error(String) }
    var status: Status = .idle
    var micOn = true { didSet { tx?.muted = !micOn } }
    var speaker = true

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fmt8k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
    private var rxSession: URLSession?
    private var txSession: URLSession?
    private var tx: TxStream?
    private var running = false

    // MARK: Start / Ende

    func start(store: AppStore, talk: Bool) async {
        guard !running else { return }
        running = true
        micOn = talk
        status = .connecting

        // 1) Mikrofon-Erlaubnis
        let allowed = await AVAudioApplication.requestRecordPermission()
        if !allowed { micOn = false }

        // 2) Anfragen an Home Assistant (mit Anmeldung)
        guard var rxReq = try? await store.client.authorizedRequest(path: "/api/familie_tuer/hoeren"),
              var txReq = try? await store.client.authorizedRequest(path: "/api/familie_tuer/sprechen") else {
            status = .onlyVideo("Home Assistant nicht erreichbar – nur Bild")
            return
        }

        // 3) Audio einrichten
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt8k)
            engine.prepare()
            try engine.start()
            player.play()
            applySpeaker()
        } catch {
            status = .onlyVideo("Ton konnte nicht gestartet werden – nur Bild")
            return
        }

        // 4) Hören
        rxReq.cachePolicy = .reloadIgnoringLocalCacheData
        let fmt = fmt8k
        let player = self.player
        let rx = RxDelegate(onAudio: { bytes in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(bytes.count)) else { return }
            buf.frameLength = AVAudioFrameCount(bytes.count)
            let out = buf.floatChannelData![0]
            for (i, b) in bytes.enumerated() { out[i] = Float(MuLaw.decode(b)) / 32768 }
            player.scheduleBuffer(buf, completionHandler: nil)
        }, onEnd: { [weak self] ok in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.status = ok ? .onlyVideo("Ton unterbrochen – Bild läuft weiter") : .onlyVideo("Kein Ton von der Tür – Bild läuft weiter")
            }
        }, onFirstData: { [weak self] in
            Task { @MainActor in if self?.running == true { self?.status = .live } }
        })
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        rxSession = URLSession(configuration: cfg, delegate: rx, delegateQueue: nil)
        rxSession?.dataTask(with: rxReq).resume()

        // 5) Sprechen (Dauer-Upload über Home Assistant an die Doorbird)
        txReq.httpMethod = "POST"
        startTransmit(txReq)
    }

    func stop() {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        tx?.close()
        tx = nil
        rxSession?.invalidateAndCancel()
        txSession?.invalidateAndCancel()
        rxSession = nil
        txSession = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = .idle
    }

    func toggleSpeaker() {
        speaker.toggle()
        applySpeaker()
    }

    private func applySpeaker() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    // MARK: Sprechen

    private func startTransmit(_ request: URLRequest) {
        let stream = TxStream()
        stream.muted = !micOn
        tx = stream
        var req = request
        req.setValue("audio/basic", forHTTPHeaderField: "Content-Type")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600
        let del = TxDelegate(stream: stream)
        txSession = URLSession(configuration: cfg, delegate: del, delegateQueue: nil)
        txSession?.uploadTask(withStreamedRequest: req).resume()

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, let conv = AVAudioConverter(from: inFmt, to: fmt8k) else { return }
        let out8k = fmt8k
        // läuft auf dem Audio-Thread – nur die thread-sicheren Werte von TxStream benutzen
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { buf, _ in
            let mic = !stream.muted
            let frames = AVAudioFrameCount(Double(buf.frameLength) * 8000 / inFmt.sampleRate) + 16
            guard let o = AVAudioPCMBuffer(pcmFormat: out8k, frameCapacity: frames) else { return }
            var fed = false
            conv.convert(to: o, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            let n = Int(o.frameLength)
            guard n > 0 else { return }
            let src = o.floatChannelData![0]
            var bytes = [UInt8](repeating: 0xFF, count: n)     // 0xFF = Stille in µ-law
            if mic {
                for i in 0..<n { bytes[i] = MuLaw.encode(Int16(max(-1, min(1, src[i])) * 32767)) }
            }
            stream.write(bytes)
        }
    }
}

// MARK: - G.711 µ-law

enum MuLaw {
    static func encode(_ sample: Int16) -> UInt8 {
        let bias: Int32 = 0x84, clip: Int32 = 32635
        var s = Int32(sample)
        let sign: Int32 = s < 0 ? 0x80 : 0
        if s < 0 { s = -s }
        if s > clip { s = clip }
        s += bias
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && (s & mask) == 0 { exponent -= 1; mask >>= 1 }
        let mantissa = (s >> (exponent + 3)) & 0x0F
        return UInt8(truncatingIfNeeded: ~(sign | (exponent << 4) | mantissa))
    }

    static func decode(_ byte: UInt8) -> Int16 {
        let u = ~Int32(byte) & 0xFF
        let sign = u & 0x80
        let exponent = (u >> 4) & 0x07
        let mantissa = u & 0x0F
        var s = ((mantissa << 3) + 0x84) << exponent
        s -= 0x84
        return Int16(truncatingIfNeeded: sign != 0 ? -s : s)
    }
}

// MARK: - Netzwerk-Helfer

final class RxDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let onAudio: ([UInt8]) -> Void
    let onEnd: (Bool) -> Void
    let onFirstData: () -> Void
    private var gotData = false

    init(onAudio: @escaping ([UInt8]) -> Void, onEnd: @escaping (Bool) -> Void, onFirstData: @escaping () -> Void) {
        self.onAudio = onAudio
        self.onEnd = onEnd
        self.onFirstData = onFirstData
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !gotData { gotData = true; onFirstData() }
        onAudio([UInt8](data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onEnd(gotData)
    }
}

/// Puffer zwischen Mikrofon und Upload (gebundene Streams)
final class TxStream: @unchecked Sendable {
    let input: InputStream
    private let output: OutputStream
    private let lock = NSLock()
    private var open = true
    private var _muted = false
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }

    init() {
        var i: InputStream?
        var o: OutputStream?
        Stream.getBoundStreams(withBufferSize: 32768, inputStream: &i, outputStream: &o)
        input = i!
        output = o!
        output.open()
    }

    func write(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard open, output.hasSpaceAvailable else { return }     // lieber verwerfen als stauen
        _ = bytes.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: bytes.count) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        open = false
        output.close()
    }
}

final class TxDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let stream: TxStream
    init(stream: TxStream) { self.stream = stream }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(stream.input)
    }
}

// MARK: - Bildschirm

struct DoorCallView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let autoTalk: Bool
    @State private var call = DoorCall()
    @State private var image: UIImage?
    @State private var opening = false
    @State private var opened = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    if image != nil {
                        Text("● LIVE")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.red.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }
                .padding(.horizontal)

                statusLine

                Spacer()

                HStack(spacing: 22) {
                    roundButton(call.micOn ? "mic.fill" : "mic.slash.fill", call.micOn ? "Mikro an" : "Stumm",
                                tint: call.micOn ? .white : .gray) { call.micOn.toggle() }
                    roundButton(call.speaker ? "speaker.wave.3.fill" : "iphone", call.speaker ? "Lautsprecher" : "Hörer",
                                tint: .white) { call.toggleSpeaker() }
                    roundButton(opened ? "checkmark" : "lock.open.fill", opened ? "Offen" : "Öffnen",
                                tint: .orange) { Task { await openDoor() } }
                        .disabled(opening || !(store.isParent && store.activeKid == nil))
                }

                Button {
                    call.stop()
                    dismiss()
                } label: {
                    Label("Auflegen", systemImage: "phone.down.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
            }
            .padding(.top, 20)
        }
        .preferredColorScheme(.dark)
        .task { await call.start(store: store, talk: autoTalk) }
        .task { await pollImage() }
        .onDisappear { call.stop() }
        .sensoryFeedback(.success, trigger: opened)
    }

    @ViewBuilder private var statusLine: some View {
        switch call.status {
        case .idle, .connecting:
            Label("Verbinde mit der Haustür …", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case .live:
            Label(call.micOn ? "Gespräch läuft – einfach sprechen" : "Du hörst zu – Mikro ist aus",
                  systemImage: call.micOn ? "waveform" : "ear")
                .foregroundStyle(.green)
        case .onlyVideo(let why), .error(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func roundButton(_ symbol: String, _ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 70, height: 70)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func pollImage() async {
        while !Task.isCancelled {
            if let img = await store.client.image(path: "/api/camera_proxy/\(FamilyConfig.doorbellLive)?t=\(Int(Date().timeIntervalSince1970 * 10))") {
                image = img
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func openDoor() async {
        opening = true
        defer { opening = false }
        guard await SecureAuth.confirm("Haustür öffnen") else { return }
        do {
            try await store.client.call("button", "press", ["entity_id": QuickConfig.frontDoor])
            opened = true
        } catch { store.report(error) }
    }
}
