import Foundation

/// Source de datagrammes RTP. Unicast aujourd'hui ; le multicast viendra s'y brancher.
public protocol RtpSource: AnyObject {
    /// Démarre la réception ; `onDatagram` est appelé sur le thread de réception.
    func start(onDatagram: @escaping ([UInt8]) -> Void) throws
    func stop()
}

public struct SocketError: Error, LocalizedError {
    public let call: String
    public let code: Int32
    public var errorDescription: String? { "\(call) : \(String(cString: strerror(code)))" }
}

/// Réception UDP unicast en sockets POSIX (marche aussi sur macOS, d'où les tests).
public final class UnicastUdpSource: RtpSource {
    private let port: UInt16
    private let lock = NSLock()
    private var running = false
    private var finished: DispatchSemaphore?

    public init(port: UInt16) { self.port = port }

    public func start(onDatagram: @escaping ([UInt8]) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var rcvbuf: Int32 = 4 << 20 // une image clé arrive en rafale
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000) // pour pouvoir s'arrêter
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            close(fd)
            throw SocketError(call: "bind(\(port))", code: err)
        }

        let done = DispatchSemaphore(value: 0)
        lock.withLock { running = true; finished = done }
        let thread = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while self?.isRunning == true {
                let n = recv(fd, &buf, buf.count, 0)
                if n > 0 { onDatagram(Array(buf[0..<n])) }
            }
            close(fd)
            done.signal()
        }
        thread.name = "rtp-rx"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var isRunning: Bool { lock.withLock { running } }

    /// Bloque jusqu'à la fin du thread de réception (au plus ~0,5 s).
    public func stop() {
        let done: DispatchSemaphore? = lock.withLock {
            running = false
            defer { finished = nil }
            return finished
        }
        done?.wait()
    }
}

public enum RtpSources {
    public struct MulticastNotSupported: Error, LocalizedError {
        public let group: String
        public var errorDescription: String? { "Multicast \(group) pas encore géré" }
    }

    public static func forSession(_ sdp: SessionDescription) throws -> RtpSource {
        if sdp.isMulticast {
            // Multicast : IP_ADD_MEMBERSHIP + entitlement Apple com.apple.developer.networking.multicast (voir README).
            throw MulticastNotSupported(group: sdp.connectionAddress ?? "?")
        }
        return UnicastUdpSource(port: sdp.port)
    }
}

public struct RtpStats {
    public var packets = 0
    public var lostPackets = 0
    public var frames = 0
    public var droppedFrames = 0
}

/// Datagrammes -> paquets RTP -> remise en ordre -> images H.264. Indépendant d'iOS.
/// `onAccessUnit` retourne false si l'image n'a pas pu être décodée : on repart alors d'une image clé.
public final class RtpPipeline {
    private let payloadType: UInt8
    private let onAccessUnit: (AccessUnit) -> Bool
    private let reorder = ReorderBuffer()
    private let depacketizer = H264Depacketizer()
    private let lock = NSLock()
    private var _stats = RtpStats()
    public var stats: RtpStats { lock.withLock { _stats } }

    public init(payloadType: UInt8, onAccessUnit: @escaping (AccessUnit) -> Bool) {
        self.payloadType = payloadType
        self.onAccessUnit = onAccessUnit
    }

    public func onDatagram(_ data: [UInt8]) {
        guard let packet = RtpPacket(data), packet.payloadType == payloadType else { return }
        var frames = 0
        for event in reorder.push(packet) {
            switch event {
            case .discontinuity:
                depacketizer.discontinuity()
            case .packet(let p):
                for au in depacketizer.push(p) {
                    frames += 1
                    if !onAccessUnit(au) { depacketizer.discontinuity() }
                }
            }
        }
        lock.withLock {
            _stats.packets += 1
            _stats.frames += frames
            _stats.lostPackets = reorder.lostPackets
            _stats.droppedFrames = depacketizer.droppedFrames
        }
    }
}
