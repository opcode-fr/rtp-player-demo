package fr.opcode.rtpvideo.core

import java.io.Closeable
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException

/** Source de datagrammes RTP. Unicast aujourd'hui ; le multicast viendra s'y brancher. */
interface RtpSource : Closeable {
    /** Démarre la réception ; [onDatagram] est appelé sur le thread de réception. */
    fun start(onDatagram: (ByteArray, Int) -> Unit)
}

class UnicastUdpSource(private val listenPort: Int) : RtpSource {
    @Volatile private var running = false
    private var thread: Thread? = null

    override fun start(onDatagram: (ByteArray, Int) -> Unit) {
        val socket = DatagramSocket(null).apply {
            reuseAddress = true
            receiveBufferSize = 4 shl 20 // une image clé arrive en rafale
            soTimeout = 500 // pour pouvoir s'arrêter
            bind(InetSocketAddress(listenPort)) // pas `port` : dans apply, ce serait DatagramSocket.port (-1)
        }
        running = true
        thread = Thread({
            val buf = ByteArray(65536)
            val dp = DatagramPacket(buf, buf.size)
            socket.use {
                while (running) {
                    try {
                        dp.length = buf.size
                        socket.receive(dp)
                        onDatagram(buf, dp.length)
                    } catch (_: SocketTimeoutException) {
                    }
                }
            }
        }, "rtp-rx").apply { start() }
    }

    override fun close() {
        running = false
        thread?.join(1000)
        thread = null
    }
}

object RtpSources {
    fun forSession(sdp: SessionDescription): RtpSource =
        if (sdp.isMulticast) {
            // Multicast : MulticastSocket.joinGroup + WifiManager.MulticastLock (voir README).
            throw UnsupportedOperationException("Multicast ${sdp.connectionAddress} pas encore géré")
        } else {
            UnicastUdpSource(sdp.port)
        }
}

class RtpStats {
    @Volatile var packets = 0L
    @Volatile var lostPackets = 0L
    @Volatile var frames = 0L
    @Volatile var droppedFrames = 0L
}

/**
 * Datagrammes -> paquets RTP -> remise en ordre -> images H.264. Indépendant d'Android.
 * [onAccessUnit] retourne false si l'image n'a pas pu être décodée : on repart alors d'une image clé.
 */
class RtpPipeline(
    private val payloadType: Int,
    private val onAccessUnit: (AccessUnit) -> Boolean,
) {
    val stats = RtpStats()
    private val depacketizer = H264Depacketizer()
    private val reorder = ReorderBuffer()

    fun onDatagram(data: ByteArray, length: Int) {
        val packet = RtpPacket.parse(data, length) ?: return
        if (packet.payloadType != payloadType) return
        stats.packets++
        for (event in reorder.push(packet)) {
            when (event) {
                ReorderBuffer.Event.Discontinuity -> depacketizer.discontinuity()
                is ReorderBuffer.Event.Packet -> depacketizer.push(event.packet).forEach {
                    stats.frames++
                    if (!onAccessUnit(it)) depacketizer.discontinuity()
                }
            }
        }
        stats.lostPackets = reorder.lostPackets
        stats.droppedFrames = depacketizer.droppedFrames
    }
}
