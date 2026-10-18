/// Remet les paquets RTP dans l'ordre et détecte les pertes.
///
/// La fenêtre est en nombre de paquets, pas en temps : simple et déterministe, suffisant en réseau
/// local. Quand un trou persiste alors que `window` paquets attendent, il est déclaré perdu.
/// En production, préférer une fenêtre en millisecondes (latence bornée même à bas débit).
public final class ReorderBuffer {
    public enum Event {
        case packet(RtpPacket)
        /// Paquets perdus ou source redémarrée : l'image en cours est inexploitable.
        case discontinuity
    }

    public private(set) var lostPackets = 0
    private let window: Int
    private var pending: [UInt16: RtpPacket] = [:]
    private var expected: UInt16?
    private var ssrc: UInt32?
    private static let resyncJump = 3000

    public init(window: Int = 32) { self.window = window }

    public func push(_ packet: RtpPacket) -> [Event] {
        var out: [Event] = []
        if let ssrc, packet.ssrc != ssrc { // le serveur a redémarré
            pending.removeAll()
            expected = nil
            out.append(.discontinuity)
        }
        ssrc = packet.ssrc

        let exp = expected ?? packet.sequence
        let diff = seqDiff(packet.sequence, exp)
        if diff < 0 { return out } // en retard ou doublon : trop tard, on jette
        if diff > Self.resyncJump {
            lostPackets += diff
            pending.removeAll()
            expected = packet.sequence
            out.append(.discontinuity)
        } else {
            expected = exp
        }
        pending[packet.sequence] = packet
        drain(&out)

        while pending.count >= window, let exp = expected {
            let next = pending.keys.min { seqDiff($0, exp) < seqDiff($1, exp) }!
            lostPackets += seqDiff(next, exp)
            expected = next
            out.append(.discontinuity)
            drain(&out)
        }
        return out
    }

    private func drain(_ out: inout [Event]) {
        while let exp = expected, let p = pending.removeValue(forKey: exp) {
            out.append(.packet(p))
            expected = exp &+ 1
        }
    }
}
