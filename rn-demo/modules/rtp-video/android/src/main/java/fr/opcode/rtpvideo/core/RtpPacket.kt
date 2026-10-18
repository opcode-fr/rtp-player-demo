package fr.opcode.rtpvideo.core

/** Paquet RTP (RFC 3550 §5.1). */
class RtpPacket(
    val marker: Boolean,
    val payloadType: Int,
    val sequence: Int,
    val timestamp: Long,
    val ssrc: Long,
    val payload: ByteArray,
) {
    companion object {
        /** Retourne null si le datagramme n'est pas un paquet RTP v2 valide. */
        fun parse(data: ByteArray, length: Int = data.size): RtpPacket? {
            if (length < 12) return null
            val b0 = data[0].toInt() and 0xFF
            if (b0 ushr 6 != 2) return null
            val hasPadding = (b0 and 0x20) != 0
            val hasExtension = (b0 and 0x10) != 0
            val csrcCount = b0 and 0x0F
            val b1 = data[1].toInt() and 0xFF

            var offset = 12 + 4 * csrcCount
            if (hasExtension) {
                if (length < offset + 4) return null
                offset += 4 + 4 * u16(data, offset + 2)
            }
            var end = length
            if (hasPadding) end -= data[length - 1].toInt() and 0xFF
            if (end < offset) return null

            return RtpPacket(
                marker = (b1 and 0x80) != 0,
                payloadType = b1 and 0x7F,
                sequence = u16(data, 2),
                timestamp = u32(data, 4),
                ssrc = u32(data, 8),
                payload = data.copyOfRange(offset, end),
            )
        }

        internal fun u16(d: ByteArray, i: Int): Int =
            ((d[i].toInt() and 0xFF) shl 8) or (d[i + 1].toInt() and 0xFF)

        private fun u32(d: ByteArray, i: Int): Long =
            (u16(d, i).toLong() shl 16) or u16(d, i + 2).toLong()
    }
}

/** Écart signé entre deux numéros de séquence 16 bits, en tenant compte du rebouclage. */
fun seqDiff(a: Int, b: Int): Int {
    val d = (a - b) and 0xFFFF
    return if (d >= 0x8000) d - 0x10000 else d
}
