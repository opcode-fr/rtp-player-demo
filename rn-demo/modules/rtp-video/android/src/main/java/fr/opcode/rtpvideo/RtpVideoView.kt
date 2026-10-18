package fr.opcode.rtpvideo

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import fr.opcode.rtpvideo.core.H264SurfaceDecoder
import fr.opcode.rtpvideo.core.RtpPipeline
import fr.opcode.rtpvideo.core.RtpSource
import fr.opcode.rtpvideo.core.RtpSources
import fr.opcode.rtpvideo.core.SessionDescription
import fr.opcode.rtpvideo.core.acquireMulticastLock

/**
 * Vue native : la vidéo ne passe jamais par JavaScript. JS fournit le SDP et l'état lecture/arrêt,
 * et reçoit des compteurs (onStats, chaque seconde) et les erreurs (onError).
 */
class RtpVideoView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
    private val onStats by EventDispatcher<Map<String, Any>>()
    private val onError by EventDispatcher<Map<String, Any>>()

    var sdp: String = ""
    var playing: Boolean = false

    private val surfaceView = SurfaceView(context)
    private val ui = Handler(Looper.getMainLooper())
    private var surfaceReady = false

    // Session en cours : on la recrée si le SDP change.
    private var activeSdp: String? = null
    private var source: RtpSource? = null
    private var decoder: H264SurfaceDecoder? = null
    private var pipeline: RtpPipeline? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    init {
        addView(surfaceView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                surfaceReady = true
                applyState()
            }
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hgt: Int) = Unit
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                surfaceReady = false
                stop()
            }
        })
    }

    /** Appelé après chaque mise à jour des props (OnViewDidUpdateProps). */
    fun applyState() {
        val wanted = if (playing && surfaceReady) sdp else null
        if (wanted == activeSdp) return
        stop()
        if (wanted != null) start(wanted)
    }

    private fun start(sdpText: String) {
        try {
            val sdp = SessionDescription.parse(sdpText)
            val dec = H264SurfaceDecoder(surfaceView.holder.surface, sdp.sps, sdp.pps)
            decoder = dec
            val pipe = RtpPipeline(sdp.payloadType, dec::decode)
            pipeline = pipe
            if (sdp.isMulticast) multicastLock = context.acquireMulticastLock()
            source = RtpSources.forSession(sdp).also { it.start(pipe::onDatagram) }
            activeSdp = sdpText
            ui.post(statsTicker)
        } catch (e: Exception) {
            Log.e(TAG, "Lecture impossible", e)
            stop()
            onError(mapOf("message" to (e.message ?: e.toString())))
        }
    }

    fun stop() {
        ui.removeCallbacks(statsTicker)
        source?.close() // attend la fin du thread de réception avant de libérer le décodeur
        source = null
        decoder?.close()
        decoder = null
        pipeline = null
        multicastLock?.release()
        multicastLock = null
        activeSdp = null
    }

    private val statsTicker = object : Runnable {
        override fun run() {
            val s = pipeline?.stats ?: return
            onStats(
                mapOf(
                    "packets" to s.packets.toDouble(),
                    "lostPackets" to s.lostPackets.toDouble(),
                    "frames" to s.frames.toDouble(),
                    "droppedFrames" to s.droppedFrames.toDouble(),
                )
            )
            ui.postDelayed(this, 1000)
        }
    }

    override fun onDetachedFromWindow() {
        stop()
        super.onDetachedFromWindow()
    }

    private companion object {
        const val TAG = "RtpVideo"
    }
}
