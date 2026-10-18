package fr.opcode.rtpvideo.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.io.EOFException
import java.io.File

class RtpTest {
    // --- Paquets fabriqués à la main --------------------------------------------------------

    private fun packet(seq: Int, ts: Long = 0, marker: Boolean = false, payload: ByteArray, ssrc: Long = 1) =
        RtpPacket(marker, 96, seq and 0xFFFF, ts, ssrc, payload)

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test
    fun `parse un en-tete RTP avec CSRC, extension et padding`() {
        val raw = bytes(
            0xB1, 0xE0, 0x12, 0x34, // V=2 P=1 X=1 CC=1, M=1 PT=96, seq 0x1234
            0x00, 0x01, 0x00, 0x02, // ts
            0xDE, 0xAD, 0xBE, 0xEF, // ssrc
            0, 0, 0, 9, // CSRC
            0xBE, 0xDE, 0x00, 0x01, 1, 2, 3, 4, // extension d'un mot
            0x65, 0xAA, // charge utile
            0, 2, // padding (2 octets)
        )
        val p = RtpPacket.parse(raw)!!
        assertTrue(p.marker)
        assertEquals(96, p.payloadType)
        assertEquals(0x1234, p.sequence)
        assertEquals(0x10002L, p.timestamp)
        assertEquals(0xDEADBEEFL, p.ssrc)
        assertArrayEquals(bytes(0x65, 0xAA), p.payload)
    }

    @Test
    fun `rejette ce qui n'est pas du RTP v2`() {
        assertNull(RtpPacket.parse(ByteArray(11)))
        assertNull(RtpPacket.parse(ByteArray(12))) // version 0
    }

    @Test
    fun `ecart de sequence avec rebouclage`() {
        assertEquals(1, seqDiff(0, 0xFFFF))
        assertEquals(-1, seqDiff(0xFFFF, 0))
        assertEquals(10, seqDiff(15, 5))
    }

    @Test
    fun `remet dans l'ordre, y compris au rebouclage`() {
        val rb = ReorderBuffer()
        val order = listOf(0xFFFE, 0x0000, 0xFFFF, 0x0001)
        val out = order.flatMap { rb.push(packet(it, payload = bytes(1))) }
            .filterIsInstance<ReorderBuffer.Event.Packet>().map { it.packet.sequence }
        assertEquals(listOf(0xFFFE, 0xFFFF, 0x0000, 0x0001), out)
        assertEquals(0, rb.lostPackets)
    }

    @Test
    fun `declare la perte quand la fenetre est pleine`() {
        val rb = ReorderBuffer(window = 4)
        val events = (listOf(0) + (2..6)).flatMap { rb.push(packet(it, payload = bytes(1))) }
        assertTrue(events.any { it is ReorderBuffer.Event.Discontinuity })
        assertEquals(1, rb.lostPackets)
        val seqs = events.filterIsInstance<ReorderBuffer.Event.Packet>().map { it.packet.sequence }
        assertEquals(listOf(0, 2, 3, 4, 5, 6), seqs)
    }

    @Test
    fun `reassemble un FU-A et lit un STAP-A`() {
        val d = H264Depacketizer()
        val sps = bytes(0x67, 1, 2)
        val pps = bytes(0x68, 3)
        val stap = bytes(0x78, 0, 3) + sps + bytes(0, 2) + pps
        val fuStart = bytes(0x7C, 0x85, 0xA1, 0xA2) // FU-A, S=1, type 5 (IDR)
        val fuEnd = bytes(0x7C, 0x45, 0xA3) // E=1
        assertTrue(d.push(packet(1, ts = 9, payload = stap)).isEmpty())
        assertTrue(d.push(packet(2, ts = 9, payload = fuStart)).isEmpty())
        val au = d.push(packet(3, ts = 9, marker = true, payload = fuEnd)).single()
        assertEquals(3, au.nalUnits.size)
        assertArrayEquals(sps, au.nalUnits[0])
        assertArrayEquals(pps, au.nalUnits[1])
        assertArrayEquals(bytes(0x65, 0xA1, 0xA2, 0xA3), au.nalUnits[2])
        assertTrue(au.isKeyFrame)
    }

    @Test
    fun `apres une perte, jette tout jusqu'a l'image cle`() {
        val d = H264Depacketizer()
        val idr = bytes(0x65, 1)
        val p = bytes(0x41, 2) // tranche P
        assertTrue(d.push(packet(1, ts = 1, marker = true, payload = p)).isEmpty()) // pas encore d'IDR
        assertEquals(1, d.push(packet(2, ts = 2, marker = true, payload = idr)).size)
        d.discontinuity()
        assertTrue(d.push(packet(4, ts = 3, marker = true, payload = p)).isEmpty())
        assertEquals(1, d.push(packet(5, ts = 4, marker = true, payload = idr)).size)
        assertEquals(1, d.push(packet(6, ts = 5, marker = true, payload = p)).size)
        assertEquals(2, d.droppedFrames)
    }

    // --- SDP ------------------------------------------------------------------------------

    @Test
    fun `lit le SDP produit par ffmpeg`() {
        val sdp = SessionDescription.parse(fixture("testsrc-2s.sdp").readText())
        assertEquals(5998, sdp.port)
        assertEquals(96, sdp.payloadType)
        assertEquals(NAL_SPS, nalType(sdp.sps!!))
        assertEquals(NAL_PPS, nalType(sdp.pps!!))
        assertFalse(sdp.isMulticast)
    }

    @Test
    fun `detecte le multicast`() {
        val sdp = SessionDescription.parse("c=IN IP4 239.1.2.3/32\nm=video 5004 RTP/AVP 96\n")
        assertTrue(sdp.isMulticast)
        assertNull(sdp.sps)
    }

    // --- Flux réel enregistré depuis ffmpeg (tools/stream.sh, 50 images, GOP de 25) ----------

    private fun replay(drop: (Int) -> Boolean = { false }): Pair<RtpPipeline, List<AccessUnit>> {
        val frames = ArrayList<AccessUnit>()
        val pipeline = RtpPipeline(96) { frames += it; true }
        DataInputStream(fixture("testsrc-2s.rtp").inputStream().buffered()).use { input ->
            var i = 0
            while (true) {
                val len = try { input.readUnsignedShort() } catch (_: EOFException) { break }
                val buf = ByteArray(len).also { input.readFully(it) }
                if (!drop(i++)) pipeline.onDatagram(buf, len)
            }
        }
        return pipeline to frames
    }

    @Test
    fun `flux ffmpeg complet - 50 images, 2 cles`() {
        val (pipeline, frames) = replay()
        assertEquals(50, frames.size)
        assertEquals(2, frames.count { it.isKeyFrame })
        assertTrue(frames.first().isKeyFrame)
        assertEquals(0, pipeline.stats.lostPackets)
        // horodatages strictement croissants (pas de mélange d'images)
        assertTrue(frames.zipWithNext().all { (a, b) -> b.timestamp > a.timestamp })
    }

    @Test
    fun `flux ffmpeg avec un paquet perdu - reprise a l'image cle suivante`() {
        val (_, all) = replay()
        val (pipeline, frames) = replay(drop = { it == 100 }) // dans le premier GOP
        assertEquals(1, pipeline.stats.lostPackets)
        assertTrue(frames.size in 25..49)
        // Après le trou, la première image reçue est une image clé.
        val step = all[1].timestamp - all[0].timestamp
        val resumes = frames.zipWithNext().filter { (a, b) -> b.timestamp - a.timestamp > step }
        assertTrue(resumes.all { (_, b) -> b.isKeyFrame })
        assertEquals(all.last().timestamp, frames.last().timestamp)
    }

    /** Bout en bout sur la boucle locale : vraie socket UDP, paquets envoyés comme par le serveur. */
    @Test
    fun `la socket unicast recoit le flux`() {
        val port = 5996
        val frames = java.util.concurrent.atomic.AtomicInteger()
        val pipeline = RtpPipeline(96) { frames.incrementAndGet(); true }
        val source = UnicastUdpSource(port)
        source.start(pipeline::onDatagram)
        try {
            java.net.DatagramSocket().use { tx ->
                val dest = java.net.InetSocketAddress("127.0.0.1", port)
                datagrams().forEachIndexed { i, d ->
                    tx.send(java.net.DatagramPacket(d, d.size, dest))
                    if (i % 20 == 0) Thread.sleep(2) // rythme doux, comme un vrai flux
                }
            }
            val deadline = System.currentTimeMillis() + 3000
            while (frames.get() < 50 && System.currentTimeMillis() < deadline) Thread.sleep(10)
            assertEquals(50, frames.get())
        } finally {
            source.close()
        }
    }

    private fun datagrams(): List<ByteArray> =
        DataInputStream(fixture("testsrc-2s.rtp").inputStream().buffered()).use { input ->
            buildList {
                while (true) {
                    val len = try { input.readUnsignedShort() } catch (_: EOFException) { break }
                    add(ByteArray(len).also { input.readFully(it) })
                }
            }
        }

    private fun fixture(name: String): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null && !File(dir, "fixtures/$name").exists()) dir = dir.parentFile
        return File(dir ?: error("fixtures/$name introuvable"), "fixtures/$name")
    }
}
