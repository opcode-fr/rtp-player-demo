import Foundation

/// Source de datagrammes RTP (unicast ou multicast).
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

/// Abonnement multicast : groupe, source éventuelle (SSM) et adresse IPv4 de l'interface d'écoute.
public struct MulticastMembership {
    public let group: String
    public let source: String?
    public let interfaceAddress: String
}

/// Réception UDP en sockets POSIX, unicast ou multicast (marche aussi sur macOS, d'où les tests).
///
/// Sur un vrai iPhone, le multicast exige l'entitlement `com.apple.developer.networking.multicast`
/// (accordé par Apple sur demande) ; sans lui, l'abonnement échoue ou rien n'arrive.
public final class UdpSource: RtpSource {
    private let port: UInt16
    private let multicast: MulticastMembership?
    private let lock = NSLock()
    private var running = false
    private var finished: DispatchSemaphore?

    public init(port: UInt16, multicast: MulticastMembership? = nil) {
        self.port = port
        self.multicast = multicast
    }

    public func start(onDatagram: @escaping ([UInt8]) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
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
        if let multicast {
            do { try join(fd, multicast) } catch { close(fd); throw error }
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

    private func join(_ fd: Int32, _ m: MulticastMembership) throws {
        let group = try ipv4(m.group), iface = try ipv4(m.interfaceAddress)
        let rc: Int32
        if let source = m.source { // SSM : uniquement les paquets de cette source
            var mreq = ip_mreq_source(imr_multiaddr: group, imr_sourceaddr: try ipv4(source), imr_interface: iface)
            rc = setsockopt(fd, IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq_source>.size))
        } else {
            var mreq = ip_mreq(imr_multiaddr: group, imr_interface: iface)
            rc = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        }
        guard rc == 0 else { throw SocketError(call: "join(\(m.group))", code: errno) }
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

func ipv4(_ s: String) throws -> in_addr {
    var a = in_addr()
    guard inet_pton(AF_INET, s, &a) == 1 else { throw SocketError(call: "adresse \(s)", code: EINVAL) }
    return a
}

public enum RtpSources {
    public struct NoMulticastInterface: Error, LocalizedError {
        public let name: String?
        public var errorDescription: String? {
            "Aucune interface réseau multicast\(name.map { " nommée \($0)" } ?? "") avec une adresse IPv4"
        }
    }

    /// Choisit la source selon la ligne c= du SDP. `multicastInterface` : nom de l'interface
    /// (« en0 » = Wi-Fi sur iPhone) ; par défaut en0, sinon la première interface multicast active.
    public static func forSession(_ sdp: SessionDescription, multicastInterface: String? = nil) throws -> RtpSource {
        guard sdp.isMulticast, let group = sdp.connectionAddress else { return UdpSource(port: sdp.port) }
        guard let iface = interfaceAddress(named: multicastInterface) else {
            throw NoMulticastInterface(name: multicastInterface)
        }
        return UdpSource(port: sdp.port,
                         multicast: MulticastMembership(group: group, source: sdp.sourceAddress, interfaceAddress: iface))
    }

    /// Adresse IPv4 de l'interface demandée, ou de la meilleure interface multicast active.
    static func interfaceAddress(named name: String?) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var found: [(name: String, address: String)] = []
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let flags = Int32(ifa.ifa_flags)
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_MULTICAST != 0 else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            found.append((String(cString: ifa.ifa_name), String(cString: buf)))
        }
        if let name { return found.first { $0.name == name }?.address }
        return (found.first { $0.name == "en0" } ?? found.first { !$0.name.hasPrefix("lo") })?.address
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
