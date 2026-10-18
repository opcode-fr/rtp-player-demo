package fr.opcode.rtpvideo

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class RtpVideoModule : Module() {
    override fun definition() = ModuleDefinition {
        Name("RtpVideo")

        View(RtpVideoView::class) {
            Events("onStats", "onError")

            Prop("sdp") { view: RtpVideoView, sdp: String -> view.sdp = sdp }
            Prop("playing") { view: RtpVideoView, playing: Boolean -> view.playing = playing }

            // Une seule réconciliation quand plusieurs props changent ensemble.
            OnViewDidUpdateProps { view: RtpVideoView -> view.applyState() }
            OnViewDestroys { view: RtpVideoView -> view.stop() }
        }
    }
}
