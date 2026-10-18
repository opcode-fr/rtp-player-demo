package fr.opcode.rtpvideo.core

import java.io.Closeable
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.net.StandardProtocolFamily
import java.net.StandardSocketOptions
import java.nio.ByteBuffer
import java.nio.channels.ClosedChannelException
import java.nio.channels.DatagramChannel

/** Source de datagrammes RTP (unicast ou multicast). */
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

/**
 * Réception multicast, avec filtre de source optionnel (SSM).
 * Sur Android, garder un WifiManager.MulticastLock pendant la lecture (voir [acquireMulticastLock]),
 * sinon le Wi-Fi jette les paquets multicast pour économiser la batterie.
 */
class MulticastUdpSource(
    private val group: InetAddress,
    private val listenPort: Int,
    private val source: InetAddress?,
    private val networkInterface: NetworkInterface,
) : RtpSource {
    private var channel: DatagramChannel? = null
    private var thread: Thread? = null

    override fun start(onDatagram: (ByteArray, Int) -> Unit) {
        val ch = DatagramChannel.open(StandardProtocolFamily.INET)
            .setOption(StandardSocketOptions.SO_REUSEADDR, true)
            .setOption(StandardSocketOptions.SO_RCVBUF, 4 shl 20)
            .bind(InetSocketAddress(listenPort))
        try {
            if (source != null) ch.join(group, networkInterface, source) else ch.join(group, networkInterface)
        } catch (e: Exception) {
            ch.close()
            throw e
        }
        channel = ch
        thread = Thread({
            val buf = ByteBuffer.allocate(65536)
            try {
                while (true) {
                    buf.clear()
                    ch.receive(buf) // bloquant ; close() le débloque
                    onDatagram(buf.array(), buf.position())
                }
            } catch (_: ClosedChannelException) {
            }
        }, "rtp-rx-mc").apply { start() }
    }

    override fun close() {
        channel?.close() // quitte aussi le groupe
        thread?.join(1000)
        channel = null
        thread = null
    }
}

object RtpSources {
    /**
     * Choisit la source selon la ligne c= du SDP. [multicastInterface] : interface d'écoute
     * multicast ; par défaut le Wi-Fi (wlan*), sinon la première interface multicast active.
     */
    fun forSession(sdp: SessionDescription, multicastInterface: NetworkInterface? = null): RtpSource {
        if (!sdp.isMulticast) return UnicastUdpSource(sdp.port)
        return MulticastUdpSource(
            group = InetAddress.getByName(sdp.connectionAddress),
            listenPort = sdp.port,
            source = sdp.sourceAddress?.let(InetAddress::getByName),
            networkInterface = multicastInterface ?: defaultMulticastInterface(),
        )
    }

    fun defaultMulticastInterface(): NetworkInterface =
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && it.supportsMulticast() }
            .filter { nif -> nif.inetAddresses.toList().any { it is Inet4Address } }
            .minByOrNull { if (it.name.startsWith("wlan")) 0 else 1 }
            ?: error("Aucune interface réseau multicast avec une adresse IPv4")
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
