import Foundation
import XCTest
@testable import RtpCore

final class RtpCoreTests: XCTestCase {
    private func packet(_ seq: UInt16, ts: UInt32 = 0, marker: Bool = false, _ payload: [UInt8], ssrc: UInt32 = 1) -> RtpPacket {
        RtpPacket(marker: marker, payloadType: 96, sequence: seq, timestamp: ts, ssrc: ssrc, payload: payload)
    }

    private func seqs(_ events: [ReorderBuffer.Event]) -> [UInt16] {
        events.compactMap { if case .packet(let p) = $0 { return p.sequence } else { return nil } }
    }

    func testParseHeaderWithCsrcExtensionAndPadding() throws {
        let raw: [UInt8] = [
            0xB1, 0xE0, 0x12, 0x34, 0x00, 0x01, 0x00, 0x02, 0xDE, 0xAD, 0xBE, 0xEF,
            0, 0, 0, 9, // CSRC
            0xBE, 0xDE, 0x00, 0x01, 1, 2, 3, 4, // extension
            0x65, 0xAA, // charge utile
            0, 2, // padding
        ]
        let p = try XCTUnwrap(RtpPacket(raw))
        XCTAssertTrue(p.marker)
        XCTAssertEqual(p.payloadType, 96)
        XCTAssertEqual(p.sequence, 0x1234)
        XCTAssertEqual(p.timestamp, 0x10002)
        XCTAssertEqual(p.ssrc, 0xDEADBEEF)
        XCTAssertEqual(p.payload, [0x65, 0xAA])
    }

    func testRejectsNonRtp() {
        XCTAssertNil(RtpPacket([UInt8](repeating: 0, count: 11)))
        XCTAssertNil(RtpPacket([UInt8](repeating: 0, count: 12)))
    }

    func testSeqDiffWraps() {
        XCTAssertEqual(seqDiff(0, 0xFFFF), 1)
        XCTAssertEqual(seqDiff(0xFFFF, 0), -1)
    }

    func testReordersAcrossWrap() {
        let rb = ReorderBuffer()
        let out = [0xFFFE, 0x0000, 0xFFFF, 0x0001].flatMap { rb.push(packet(UInt16($0), [1])) }
        XCTAssertEqual(seqs(out), [0xFFFE, 0xFFFF, 0x0000, 0x0001])
        XCTAssertEqual(rb.lostPackets, 0)
    }

    func testDeclaresLossWhenWindowFull() {
        let rb = ReorderBuffer(window: 4)
        let events = [0, 2, 3, 4, 5, 6].flatMap { rb.push(packet(UInt16($0), [1])) }
        XCTAssertTrue(events.contains { if case .discontinuity = $0 { return true } else { return false } })
        XCTAssertEqual(rb.lostPackets, 1)
        XCTAssertEqual(seqs(events), [0, 2, 3, 4, 5, 6])
    }

    func testFuAAndStapA() throws {
        let d = H264Depacketizer()
        let sps: [UInt8] = [0x67, 1, 2], pps: [UInt8] = [0x68, 3]
        let stap: [UInt8] = [0x78, 0, 3] + sps + [0, 2] + pps
        XCTAssertTrue(d.push(packet(1, ts: 9, stap)).isEmpty)
        XCTAssertTrue(d.push(packet(2, ts: 9, [0x7C, 0x85, 0xA1, 0xA2])).isEmpty)
        let au = try XCTUnwrap(d.push(packet(3, ts: 9, marker: true, [0x7C, 0x45, 0xA3])).first)
        XCTAssertEqual(au.nalUnits, [sps, pps, [0x65, 0xA1, 0xA2, 0xA3]])
        XCTAssertTrue(au.isKeyFrame)
    }

    func testDropsUntilKeyFrameAfterLoss() {
        let d = H264Depacketizer()
        let idr: [UInt8] = [0x65, 1], p: [UInt8] = [0x41, 2]
        XCTAssertTrue(d.push(packet(1, ts: 1, marker: true, p)).isEmpty)
        XCTAssertEqual(d.push(packet(2, ts: 2, marker: true, idr)).count, 1)
        d.discontinuity()
        XCTAssertTrue(d.push(packet(4, ts: 3, marker: true, p)).isEmpty)
        XCTAssertEqual(d.push(packet(5, ts: 4, marker: true, idr)).count, 1)
        XCTAssertEqual(d.push(packet(6, ts: 5, marker: true, p)).count, 1)
        XCTAssertEqual(d.droppedFrames, 2)
    }

    // MARK: SDP

    func testParsesFfmpegSdp() throws {
        let sdp = try SessionDescription.parse(String(contentsOf: fixture("testsrc-2s.sdp"), encoding: .utf8))
        XCTAssertEqual(sdp.port, 5998)
        XCTAssertEqual(sdp.payloadType, 96)
        XCTAssertEqual(sdp.sps.map(nalType), NalType.sps)
        XCTAssertEqual(sdp.pps.map(nalType), NalType.pps)
        XCTAssertFalse(sdp.isMulticast)
    }

    func testDetectsMulticast() throws {
        let sdp = try SessionDescription.parse("c=IN IP4 239.1.2.3/32\nm=video 5004 RTP/AVP 96\n")
        XCTAssertTrue(sdp.isMulticast)
        XCTAssertNil(sdp.sps)
        XCTAssertThrowsError(try RtpSources.forSession(sdp))
    }

    // MARK: Flux réel enregistré depuis ffmpeg (50 images, GOP de 25)

    private func datagrams() throws -> [[UInt8]] {
        let bytes = try [UInt8](Data(contentsOf: fixture("testsrc-2s.rtp")))
        var out: [[UInt8]] = [], i = 0
        while i + 2 <= bytes.count {
            let len = Int(u16(bytes, i))
            out.append(Array(bytes[i + 2..<i + 2 + len]))
            i += 2 + len
        }
        return out
    }

    private func replay(dropping drop: Int? = nil) throws -> (RtpPipeline, [AccessUnit]) {
        var frames: [AccessUnit] = []
        let pipeline = RtpPipeline(payloadType: 96) { frames.append($0); return true }
        for (i, d) in try datagrams().enumerated() where i != drop { pipeline.onDatagram(d) }
        return (pipeline, frames)
    }

    func testFullFfmpegStream() throws {
        let (pipeline, frames) = try replay()
        XCTAssertEqual(frames.count, 50)
        XCTAssertEqual(frames.filter(\.isKeyFrame).count, 2)
        XCTAssertTrue(frames[0].isKeyFrame)
        XCTAssertEqual(pipeline.stats.lostPackets, 0)
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $1.timestamp > $0.timestamp })
    }

    func testFfmpegStreamWithOneLostPacketResumesOnKeyFrame() throws {
        let (_, all) = try replay()
        let (pipeline, frames) = try replay(dropping: 100)
        XCTAssertEqual(pipeline.stats.lostPackets, 1)
        XCTAssertTrue((25...49).contains(frames.count))
        let step = all[1].timestamp - all[0].timestamp
        for (a, b) in zip(frames, frames.dropFirst()) where b.timestamp - a.timestamp > step {
            XCTAssertTrue(b.isKeyFrame)
        }
        XCTAssertEqual(frames.last?.timestamp, all.last?.timestamp)
    }

    /// Bout en bout sur la boucle locale : vraie socket UDP, paquets envoyés comme par le serveur.
    func testUnicastSocketReceivesStream() throws {
        let port: UInt16 = 5997
        let lock = NSLock()
        var frames = 0
        let pipeline = RtpPipeline(payloadType: 96) { _ in lock.withLock { frames += 1 }; return true }
        let source = UnicastUdpSource(port: port)
        try source.start(onDatagram: pipeline.onDatagram)
        defer { source.stop() }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        for (i, d) in try datagrams().enumerated() {
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, d, d.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if i % 20 == 0 { usleep(2000) } // rythme doux, comme un vrai flux
        }
        let deadline = Date().addingTimeInterval(3)
        while lock.withLock({ frames }) < 50, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(lock.withLock { frames }, 50)
    }

    private func fixture(_ name: String) -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("fixtures/\(name)").path) {
            dir.deleteLastPathComponent()
        }
        return dir.appendingPathComponent("fixtures/\(name)")
    }
}
