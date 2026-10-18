import Foundation

/// Paquet RTP (RFC 3550 §5.1).
public struct RtpPacket {
    public let marker: Bool
    public let payloadType: UInt8
    public let sequence: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let payload: [UInt8]

    public init(marker: Bool, payloadType: UInt8, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: [UInt8]) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    /// Retourne nil si le datagramme n'est pas un paquet RTP v2 valide.
    public init?(_ d: [UInt8]) {
        guard d.count >= 12, d[0] >> 6 == 2 else { return nil }
        let hasPadding = d[0] & 0x20 != 0
        let hasExtension = d[0] & 0x10 != 0
        var offset = 12 + 4 * Int(d[0] & 0x0F)
        if hasExtension {
            guard d.count >= offset + 4 else { return nil }
            offset += 4 + 4 * Int(u16(d, offset + 2))
        }
        var end = d.count
        if hasPadding { end -= Int(d[d.count - 1]) }
        guard end >= offset else { return nil }

        marker = d[1] & 0x80 != 0
        payloadType = d[1] & 0x7F
        sequence = u16(d, 2)
        timestamp = UInt32(u16(d, 4)) << 16 | UInt32(u16(d, 6))
        ssrc = UInt32(u16(d, 8)) << 16 | UInt32(u16(d, 10))
        payload = Array(d[offset..<end])
    }
}

@inline(__always) func u16(_ d: [UInt8], _ i: Int) -> UInt16 {
    UInt16(d[i]) << 8 | UInt16(d[i + 1])
}

/// Écart signé entre deux numéros de séquence 16 bits, en tenant compte du rebouclage.
public func seqDiff(_ a: UInt16, _ b: UInt16) -> Int {
    Int(Int16(bitPattern: a &- b))
}
