import Foundation

/// Ce dont le lecteur a besoin dans un SDP (RFC 4566) décrivant un flux H.264.
public struct SessionDescription {
    /// Adresse de la ligne c= (destination du flux) ; multicast si dans 224.0.0.0/4.
    public let connectionAddress: String?
    public let port: UInt16
    public let payloadType: UInt8
    public let sps: [UInt8]?
    public let pps: [UInt8]?

    public var isMulticast: Bool {
        guard let first = connectionAddress?.split(separator: ".").first, let o = Int(first) else { return false }
        return (224...239).contains(o)
    }

    public enum ParseError: Error, LocalizedError {
        case noVideo, unsupportedCodec(String)
        public var errorDescription: String? {
            switch self {
            case .noVideo: return "SDP sans ligne m=video exploitable"
            case .unsupportedCodec(let c): return "Codec \(c) non géré (H264 seulement)"
            }
        }
    }

    public init(connectionAddress: String?, port: UInt16, payloadType: UInt8, sps: [UInt8]?, pps: [UInt8]?) {
        self.connectionAddress = connectionAddress
        self.port = port
        self.payloadType = payloadType
        self.sps = sps
        self.pps = pps
    }

    public static func parse(_ text: String) throws -> SessionDescription {
        var address: String?
        var port: UInt16?
        var payloadType: UInt8?
        var codec: String?
        var sps: [UInt8]?
        var pps: [UInt8]?

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let fields = line.split(separator: " ").map(String.init)
            if line.hasPrefix("c=") {
                // "c=IN IP4 239.1.1.1/32" : le niveau média écrase le niveau session.
                address = fields.count > 2 ? String(fields[2].split(separator: "/")[0]) : nil
            } else if line.hasPrefix("m=video ") {
                port = fields.count > 1 ? UInt16(fields[1].split(separator: "/")[0]) : nil
                payloadType = fields.count > 3 ? UInt8(fields[3]) : nil
            } else if line.hasPrefix("a=rtpmap:"), fields.count > 1 {
                codec = String(fields[1].split(separator: "/")[0]).uppercased()
            } else if line.hasPrefix("a=fmtp:"), let space = line.firstIndex(of: " ") {
                for param in line[space...].split(separator: ";") {
                    let kv = param.trimmingCharacters(in: .whitespaces)
                    guard kv.hasPrefix("sprop-parameter-sets=") else { continue }
                    for b64 in kv.dropFirst("sprop-parameter-sets=".count).split(separator: ",") {
                        guard let data = Data(base64Encoded: padded(String(b64))), !data.isEmpty else { continue }
                        let nal = [UInt8](data)
                        switch nalType(nal) {
                        case NalType.sps: sps = nal
                        case NalType.pps: pps = nal
                        default: break
                        }
                    }
                }
            }
        }
        guard let port, let payloadType else { throw ParseError.noVideo }
        if let codec, codec != "H264" { throw ParseError.unsupportedCodec(codec) }
        return SessionDescription(connectionAddress: address, port: port, payloadType: payloadType, sps: sps, pps: pps)
    }

    private static func padded(_ s: String) -> String {
        s + String(repeating: "=", count: (4 - s.count % 4) % 4)
    }
}
