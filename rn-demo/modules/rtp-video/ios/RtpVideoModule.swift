import ExpoModulesCore

public class RtpVideoModule: Module {
  public func definition() -> ModuleDefinition {
    Name("RtpVideo")

    View(RtpVideoView.self) {
      Events("onStats", "onError")

      Prop("sdp") { (view: RtpVideoView, sdp: String) in view.sdp = sdp }
      Prop("playing") { (view: RtpVideoView, playing: Bool) in view.playing = playing }

      // Une seule réconciliation quand plusieurs props changent ensemble.
      OnViewDidUpdateProps { (view: RtpVideoView) in view.applyState() }
    }
  }
}
