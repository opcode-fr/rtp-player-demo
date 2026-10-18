package fr.opcode.rtpvideo.core

/**
 * Remet les paquets RTP dans l'ordre et détecte les pertes.
 *
 * La fenêtre est en nombre de paquets, pas en temps : simple et déterministe, suffisant en réseau
 * local. Quand un trou persiste alors que [window] paquets attendent, il est déclaré perdu.
 * En production, préférer une fenêtre en millisecondes (latence bornée même à bas débit).
 */
class ReorderBuffer(private val window: Int = 32) {
    sealed interface Event {
        class Packet(val packet: RtpPacket) : Event
        /** Paquets perdus ou source redémarrée : l'image en cours est inexploitable. */
        data object Discontinuity : Event
    }

    var lostPackets = 0L
        private set

    private val pending = HashMap<Int, RtpPacket>()
    private var expected: Int? = null
    private var ssrc: Long? = null

    fun push(packet: RtpPacket): List<Event> {
        val out = ArrayList<Event>(2)
        if (ssrc != null && packet.ssrc != ssrc) {
            // Le serveur a redémarré : on repart de zéro.
            pending.clear()
            expected = null
            out += Event.Discontinuity
        }
        ssrc = packet.ssrc

        val exp = expected ?: packet.sequence
        val diff = seqDiff(packet.sequence, exp)
        when {
            diff < 0 -> return out // en retard ou doublon : trop tard, on jette
            diff > RESYNC_JUMP -> { // saut énorme : resynchronisation
                lostPackets += diff
                pending.clear()
                expected = packet.sequence
                out += Event.Discontinuity
            }
            else -> expected = exp
        }
        pending[packet.sequence] = packet
        drain(out)

        while (pending.size >= window) {
            val next = pending.keys.minBy { seqDiff(it, expected!!) }
            lostPackets += seqDiff(next, expected!!)
            expected = next
            out += Event.Discontinuity
            drain(out)
        }
        return out
    }

    private fun drain(out: MutableList<Event>) {
        while (true) {
            val p = pending.remove(expected!!) ?: return
            out += Event.Packet(p)
            expected = (expected!! + 1) and 0xFFFF
        }
    }

    private companion object {
        const val RESYNC_JUMP = 3000
    }
}
