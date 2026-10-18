/// Une image complète : la liste de ses NAL (sans code de début).
public struct AccessUnit {
    public let timestamp: UInt32
    public let nalUnits: [[UInt8]]
    public var isKeyFrame: Bool { nalUnits.contains { nalType($0) == NalType.idr } }
}

public enum NalType {
    public static let idr: UInt8 = 5
    public static let sps: UInt8 = 7
    public static let pps: UInt8 = 8
    public static let aud: UInt8 = 9
}

public func nalType(_ nal: [UInt8]) -> UInt8 { nal[0] & 0x1F }

/// Reconstitue les images H.264 à partir des paquets RTP (RFC 6184, packetization-mode 0 et 1) :
/// NAL simple, STAP-A et FU-A.
///
/// Après une perte, tout est jeté jusqu'à la prochaine image clé (IDR) : sans retransmission ni
/// moyen de demander une image clé au serveur, c'est la seule stratégie sûre.
public final class H264Depacketizer {
    private var nals: [[UInt8]] = []
    private var timestamp: UInt32?
    private var fragment: [UInt8]?
    private var corrupted = false
    private var waitingForKeyFrame = true
    public private(set) var droppedFrames = 0

    private static let stapA: UInt8 = 24
    private static let fuA: UInt8 = 28

    public init() {}

    /// À appeler sur perte de paquets, ou quand le décodeur a raté une image.
    public func discontinuity() {
        fragment = nil
        corrupted = true
        waitingForKeyFrame = true
    }

    public func push(_ packet: RtpPacket) -> [AccessUnit] {
        var out: [AccessUnit] = []
        // Changement d'horodatage sans bit marker : l'image précédente est terminée.
        if let ts = timestamp, ts != packet.timestamp { flush(&out) }
        timestamp = packet.timestamp

        let p = packet.payload
        if !p.isEmpty {
            switch p[0] & 0x1F {
            case 1...23: nals.append(p)
            case Self.stapA: readStapA(p)
            case Self.fuA: readFuA(p)
            default: break // STAP-B/MTAP/FU-B : packetization-mode 2, non géré
            }
        }
        if packet.marker { flush(&out) }
        return out
    }

    private func readStapA(_ p: [UInt8]) {
        var i = 1
        while i + 2 <= p.count {
            let len = Int(u16(p, i))
            i += 2
            guard len > 0, i + len <= p.count else { corrupted = true; return }
            nals.append(Array(p[i..<i + len]))
            i += len
        }
    }

    private func readFuA(_ p: [UInt8]) {
        guard p.count >= 2 else { corrupted = true; return }
        let header = p[1]
        if header & 0x80 != 0 { // début : en-tête NAL reconstitué
            fragment = [(p[0] & 0xE0) | (header & 0x1F)]
            fragment!.reserveCapacity(p.count * 8)
        }
        guard fragment != nil else { return } // début manqué : la perte a déjà été signalée
        fragment!.append(contentsOf: p[2...])
        if header & 0x40 != 0 { // fin
            nals.append(fragment!)
            fragment = nil
        }
    }

    private func flush(_ out: inout [AccessUnit]) {
        if fragment != nil { corrupted = true } // fragment non terminé
        let au = AccessUnit(timestamp: timestamp ?? 0, nalUnits: nals)
        let broken = corrupted
        nals = []
        fragment = nil
        corrupted = false
        timestamp = nil
        guard !au.nalUnits.isEmpty else { return }

        if broken {
            waitingForKeyFrame = true
            droppedFrames += 1
        } else if waitingForKeyFrame && !au.isKeyFrame {
            droppedFrames += 1
        } else {
            waitingForKeyFrame = false
            out.append(au)
        }
    }
}
