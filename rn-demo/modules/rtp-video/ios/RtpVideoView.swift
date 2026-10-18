import AVFoundation
import ExpoModulesCore

/// Vue native : la vidéo ne passe jamais par JavaScript. JS fournit le SDP et l'état lecture/arrêt,
/// et reçoit des compteurs (onStats, chaque seconde) et les erreurs (onError).
class RtpVideoView: ExpoView {
    let onStats = EventDispatcher()
    let onError = EventDispatcher()

    var sdp = ""
    var playing = false

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var activeSdp: String?
    private var source: RtpSource?
    private var pipeline: RtpPipeline?
    private var timer: Timer?

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    /// Appelé après chaque mise à jour des props (OnViewDidUpdateProps).
    func applyState() {
        let wanted = playing ? sdp : nil
        if wanted == activeSdp { return }
        stop()
        if let wanted { start(wanted) }
    }

    private func start(_ text: String) {
        do {
            let sdp = try SessionDescription.parse(text)
            let renderer = H264LayerRenderer(layer: displayLayer, sps: sdp.sps, pps: sdp.pps)
            let pipe = RtpPipeline(payloadType: sdp.payloadType, onAccessUnit: renderer.render)
            let src = try RtpSources.forSession(sdp)
            try src.start(onDatagram: pipe.onDatagram)
            source = src
            pipeline = pipe
            activeSdp = text
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let s = self?.pipeline?.stats else { return }
                self?.onStats([
                    "packets": s.packets, "lostPackets": s.lostPackets,
                    "frames": s.frames, "droppedFrames": s.droppedFrames,
                ])
            }
        } catch {
            stop()
            onError(["message": error.localizedDescription])
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source?.stop() // attend la fin du thread de réception
        source = nil
        pipeline = nil
        activeSdp = nil
    }

    override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }
}
