package fr.opcode.rtpdemo

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import fr.opcode.rtpdemo.rtp.AccessUnit
import java.nio.ByteBuffer

/**
 * Décodage matériel H.264 via MediaCodec, rendu direct dans une Surface.
 * Appelé depuis le thread de réception : mode synchrone, sans file intermédiaire.
 */
class H264SurfaceDecoder(surface: Surface, sps: ByteArray?, pps: ByteArray?) : AutoCloseable {
    private val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val info = MediaCodec.BufferInfo()
    private var firstTimestamp = -1L

    init {
        // Taille indicative : le décodeur lit la vraie résolution dans le SPS.
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080).apply {
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 2 shl 20)
            if (sps != null && pps != null) { // sinon, SPS/PPS attendus dans le flux
                setByteBuffer("csd-0", ByteBuffer.wrap(START_CODE + sps))
                setByteBuffer("csd-1", ByteBuffer.wrap(START_CODE + pps))
            }
        }
        codec.configure(format, surface, null, 0)
        codec.start()
    }

    /** Retourne false si l'image n'a pas pu être soumise (le flux doit repartir d'une image clé). */
    fun decode(au: AccessUnit): Boolean {
        val index = codec.dequeueInputBuffer(20_000)
        if (index < 0) return false
        val buf = codec.getInputBuffer(index)!!
        buf.clear()
        for (nal in au.nalUnits) {
            buf.put(START_CODE)
            buf.put(nal)
        }
        if (firstTimestamp < 0) firstTimestamp = au.timestamp
        val ptsUs = ((au.timestamp - firstTimestamp) and 0xFFFFFFFFL) * 100 / 9 // 90 kHz -> µs
        codec.queueInputBuffer(index, 0, buf.position(), ptsUs, 0)
        drain()
        return true
    }

    private fun drain() {
        while (true) {
            val out = codec.dequeueOutputBuffer(info, 0)
            if (out < 0) return // pas d'image prête, ou changement de format
            codec.releaseOutputBuffer(out, true) // affichage immédiat : on vise la latence
        }
    }

    override fun close() {
        runCatching { codec.stop() }
        codec.release()
    }

    private companion object {
        val START_CODE = byteArrayOf(0, 0, 0, 1)
    }
}
