package fr.opcode.rtpdemo

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import fr.opcode.rtpvideo.core.RtpPipeline
import fr.opcode.rtpvideo.core.RtpSource
import fr.opcode.rtpvideo.core.RtpSources
import fr.opcode.rtpvideo.core.SessionDescription
import fr.opcode.rtpvideo.core.H264SurfaceDecoder

/** Écran unique : le SDP du flux, Lire/Arrêter, la vidéo et quelques compteurs. */
class MainActivity : Activity() {
    private lateinit var surfaceView: SurfaceView
    private lateinit var sdpField: EditText
    private lateinit var playButton: Button
    private lateinit var statsView: TextView
    private val ui = Handler(Looper.getMainLooper())

    private var source: RtpSource? = null
    private var decoder: H264SurfaceDecoder? = null
    private var pipeline: RtpPipeline? = null
    private var surfaceReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                surfaceReady = true
                playButton.isEnabled = true
            }
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hgt: Int) = Unit
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                surfaceReady = false
                stop()
            }
        })
        sdpField = EditText(this).apply {
            setText(intent.getStringExtra("sdp") ?: DEFAULT_SDP)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            textSize = 11f
            gravity = Gravity.TOP
            minLines = 6
        }
        playButton = Button(this).apply {
            text = "Lire"
            isEnabled = false
            setOnClickListener { if (source == null) play() else stop() }
        }
        statsView = TextView(this).apply { textSize = 13f; setPadding(24, 8, 24, 8) }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true // Android 15+ : affichage bord à bord imposé
            setPadding(16, 16, 16, 16)
            // 16:9 sur la largeur de l'écran
            val width = resources.displayMetrics.widthPixels - 32
            addView(surfaceView, LinearLayout.LayoutParams(width, width * 9 / 16))
            addView(statsView)
            addView(playButton)
            addView(sdpField, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        })
        ui.post(statsTicker)
    }

    private fun play() {
        if (!surfaceReady) return
        try {
            val sdp = SessionDescription.parse(sdpField.text.toString())
            val dec = H264SurfaceDecoder(surfaceView.holder.surface, sdp.sps, sdp.pps)
            val pipe = RtpPipeline(sdp.payloadType, dec::decode)
            val src = RtpSources.forSession(sdp)
            decoder = dec
            pipeline = pipe
            source = src
            src.start(pipe::onDatagram)
            playButton.text = "Arrêter"
            Log.i(TAG, "Écoute UDP sur le port ${sdp.port}, SPS/PPS dans le SDP : ${sdp.sps != null}")
        } catch (e: Exception) {
            Log.e(TAG, "Lecture impossible", e)
            stop()
            statsView.text = "Erreur : ${e.message}"
        }
    }

    private fun stop() {
        source?.close() // attend la fin du thread de réception avant de libérer le décodeur
        source = null
        decoder?.close()
        decoder = null
        pipeline = null
        playButton.text = "Lire"
    }

    private val statsTicker = object : Runnable {
        private var lastFrames = 0L
        override fun run() {
            pipeline?.stats?.let {
                val fps = it.frames - lastFrames
                lastFrames = it.frames
                statsView.text = "paquets ${it.packets} · perdus ${it.lostPackets} · " +
                    "images ${it.frames} · jetées ${it.droppedFrames} · $fps img/s"
                Log.i(TAG, statsView.text.toString())
            }
            ui.postDelayed(this, 1000)
        }
    }

    override fun onDestroy() {
        ui.removeCallbacks(statsTicker)
        stop()
        super.onDestroy()
    }

    private companion object {
        const val TAG = "RtpDemo"

        /** Le SDP produit par tools/stream.sh. */
        val DEFAULT_SDP = """
            v=0
            o=- 0 0 IN IP4 127.0.0.1
            s=No Name
            c=IN IP4 127.0.0.1
            t=0 0
            m=video 5004 RTP/AVP 96
            a=rtpmap:96 H264/90000
            a=fmtp:96 packetization-mode=1; sprop-parameter-sets=Z0LAH9oBQBbsBEAAAAMAQAAADKPGDKg=,aM4PyA==; profile-level-id=42C01F
        """.trimIndent()
    }
}
