package fr.opcode.rtpdemo.rtp

import java.io.ByteArrayOutputStream

/** Une image complète : la liste de ses NAL (sans code de début). */
class AccessUnit(val timestamp: Long, val nalUnits: List<ByteArray>) {
    val isKeyFrame: Boolean get() = nalUnits.any { nalType(it) == NAL_IDR }
}

fun nalType(nal: ByteArray): Int = nal[0].toInt() and 0x1F

const val NAL_IDR = 5
const val NAL_SPS = 7
const val NAL_PPS = 8

/**
 * Reconstitue les images H.264 à partir des paquets RTP (RFC 6184, packetization-mode 0 et 1) :
 * NAL simple, STAP-A et FU-A.
 *
 * Après une perte, tout est jeté jusqu'à la prochaine image clé (IDR) : sans retransmission ni
 * moyen de demander une image clé au serveur, c'est la seule stratégie sûre.
 */
class H264Depacketizer {
    private val nals = ArrayList<ByteArray>()
    private var timestamp = -1L
    private var fragment: ByteArrayOutputStream? = null
    private var corrupted = false
    private var waitingForKeyFrame = true

    var droppedFrames = 0L
        private set

    /** À appeler sur perte de paquets, ou quand le décodeur a raté une image. */
    fun discontinuity() {
        fragment = null
        corrupted = true
        waitingForKeyFrame = true
    }

    fun push(packet: RtpPacket): List<AccessUnit> {
        val out = ArrayList<AccessUnit>(1)
        // Changement d'horodatage sans bit marker : l'image précédente est terminée.
        if (timestamp != -1L && packet.timestamp != timestamp) flush(out)
        timestamp = packet.timestamp

        val p = packet.payload
        if (p.isNotEmpty()) {
            when (p[0].toInt() and 0x1F) {
                in 1..23 -> nals += p
                STAP_A -> readStapA(p)
                FU_A -> readFuA(p)
                else -> Unit // STAP-B/MTAP/FU-B : packetization-mode 2, non géré
            }
        }
        if (packet.marker) flush(out)
        return out
    }

    private fun readStapA(p: ByteArray) {
        var i = 1
        while (i + 2 <= p.size) {
            val len = RtpPacket.u16(p, i)
            i += 2
            if (len == 0 || i + len > p.size) {
                corrupted = true
                return
            }
            nals += p.copyOfRange(i, i + len)
            i += len
        }
    }

    private fun readFuA(p: ByteArray) {
        if (p.size < 2) {
            corrupted = true
            return
        }
        val header = p[1].toInt() and 0xFF
        val start = (header and 0x80) != 0
        val end = (header and 0x40) != 0
        if (start) {
            fragment = ByteArrayOutputStream(p.size * 8).apply {
                write((p[0].toInt() and 0xE0) or (header and 0x1F)) // en-tête NAL reconstitué
            }
        }
        val f = fragment ?: return // début manqué : ignoré (la perte a déjà été signalée)
        f.write(p, 2, p.size - 2)
        if (end) {
            nals += f.toByteArray()
            fragment = null
        }
    }

    private fun flush(out: MutableList<AccessUnit>) {
        if (fragment != null) corrupted = true // fragment non terminé
        val au = AccessUnit(timestamp, ArrayList(nals))
        val broken = corrupted
        nals.clear()
        fragment = null
        corrupted = false
        timestamp = -1L
        if (au.nalUnits.isEmpty()) return

        when {
            broken -> {
                waitingForKeyFrame = true
                droppedFrames++
            }
            waitingForKeyFrame && !au.isKeyFrame -> droppedFrames++
            else -> {
                waitingForKeyFrame = false
                out += au
            }
        }
    }

    private companion object {
        const val STAP_A = 24
        const val FU_A = 28
    }
}
