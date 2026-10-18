import AVFoundation
import RtpCore
import SwiftUI

/// Vue UIKit dont la couche est directement un `AVSampleBufferDisplayLayer`.
final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct VideoView: UIViewRepresentable {
    let view: VideoLayerView
    func makeUIView(context: Context) -> VideoLayerView {
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: VideoLayerView, context: Context) {}
}

/// Assemble source UDP, pipeline RTP et rendu ; publie les compteurs pour l'écran.
@MainActor
final class Player: ObservableObject {
    @Published var sdpText = Player.defaultSdp
    @Published var status = ""
    @Published private(set) var isPlaying = false
    let videoView = VideoLayerView()

    private var source: RtpSource?
    private var pipeline: RtpPipeline?
    private var timer: Timer?
    private var lastFrames = 0

    func toggle() { isPlaying ? stop() : play() }

    func play() {
        do {
            let sdp = try SessionDescription.parse(sdpText)
            let (src, pipe) = try Self.startSession(sdp, layer: videoView.displayLayer)
            source = src
            pipeline = pipe
            isPlaying = true
            lastFrames = 0
            status = "Écoute UDP sur le port \(sdp.port)…"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshStats() }
            }
        } catch {
            stop()
            status = "Erreur : \(error.localizedDescription)"
        }
    }

    /// Hors MainActor : les closures tournent sur le thread de réception, pas sur le thread principal.
    nonisolated private static func startSession(
        _ sdp: SessionDescription, layer: AVSampleBufferDisplayLayer
    ) throws -> (RtpSource, RtpPipeline) {
        let renderer = H264LayerRenderer(layer: layer, sps: sdp.sps, pps: sdp.pps)
        let pipe = RtpPipeline(payloadType: sdp.payloadType, onAccessUnit: renderer.render)
        let src = try RtpSources.forSession(sdp)
        try src.start(onDatagram: pipe.onDatagram)
        return (src, pipe)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source?.stop()
        source = nil
        pipeline = nil
        isPlaying = false
    }

    private func refreshStats() {
        guard let s = pipeline?.stats else { return }
        status = "paquets \(s.packets) · perdus \(s.lostPackets) · images \(s.frames) · jetées \(s.droppedFrames) · \(s.frames - lastFrames) img/s"
        lastFrames = s.frames
        print("RtpDemo", status)
    }

    /// Le SDP produit par tools/stream.sh.
    static let defaultSdp = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=No Name
    c=IN IP4 127.0.0.1
    t=0 0
    m=video 5004 RTP/AVP 96
    a=rtpmap:96 H264/90000
    a=fmtp:96 packetization-mode=1; sprop-parameter-sets=Z0LAH9oBQBbsBEAAAAMAQAAADKPGDKg=,aM4PyA==; profile-level-id=42C01F
    """
}

struct ContentView: View {
    @StateObject private var player = Player()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoView(view: player.videoView)
                .aspectRatio(16 / 9, contentMode: .fit)
            Text(player.status).font(.footnote.monospacedDigit())
            Button(player.isPlaying ? "Arrêter" : "Lire") { player.toggle() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("play")
            Text("SDP du flux").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $player.sdpText)
                .font(.system(size: 11, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .border(.gray.opacity(0.4))
        }
        .padding()
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-autoplay") { player.play() } }
    }
}

@main
struct RtpPlayerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
