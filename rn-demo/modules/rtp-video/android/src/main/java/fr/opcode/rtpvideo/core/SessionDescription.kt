package fr.opcode.rtpvideo.core

import java.util.Base64

/** Ce dont le lecteur a besoin dans un SDP (RFC 4566) décrivant un flux H.264. */
class SessionDescription(
    /** Adresse de la ligne c= (destination du flux) ; multicast si dans 224.0.0.0/4. */
    val connectionAddress: String?,
    val port: Int,
    val payloadType: Int,
    val sps: ByteArray?,
    val pps: ByteArray?,
) {
    val isMulticast: Boolean
        get() = connectionAddress?.substringBefore('.')?.toIntOrNull() in 224..239

    companion object {
        fun parse(text: String): SessionDescription {
            var address: String? = null
            var port: Int? = null
            var payloadType: Int? = null
            var codec: String? = null
            var sps: ByteArray? = null
            var pps: ByteArray? = null

            for (raw in text.lineSequence()) {
                val line = raw.trim()
                when {
                    line.startsWith("c=") ->
                        // "c=IN IP4 239.1.1.1/32" : le niveau média écrase le niveau session.
                        address = line.removePrefix("c=").split(' ').getOrNull(2)?.substringBefore('/')
                    line.startsWith("m=video ") -> {
                        val f = line.removePrefix("m=").split(' ')
                        port = f.getOrNull(1)?.substringBefore('/')?.toIntOrNull()
                        payloadType = f.getOrNull(3)?.toIntOrNull()
                    }
                    line.startsWith("a=rtpmap:") ->
                        codec = line.substringAfter(' ').substringBefore('/').uppercase()
                    line.startsWith("a=fmtp:") -> {
                        val params = line.substringAfter(' ').split(';').map { it.trim() }
                        params.firstOrNull { it.startsWith("sprop-parameter-sets=") }
                            ?.substringAfter('=')
                            ?.split(',')
                            ?.mapNotNull { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
                            ?.filter { it.isNotEmpty() }
                            ?.forEach {
                                when (nalType(it)) {
                                    NAL_SPS -> sps = it
                                    NAL_PPS -> pps = it
                                }
                            }
                    }
                }
            }
            require(port != null && payloadType != null) { "SDP sans ligne m=video exploitable" }
            require(codec == null || codec == "H264") { "Codec $codec non géré (H264 seulement)" }
            return SessionDescription(address, port, payloadType, sps, pps)
        }
    }
}
