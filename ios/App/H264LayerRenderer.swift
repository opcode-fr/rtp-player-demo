import AVFoundation
import CoreMedia
import RtpCore

/// Décodage matériel et affichage : `AVSampleBufferDisplayLayer` décode le H.264 (VideoToolbox)
/// et affiche dans la foulée. Le H.264 réseau (NAL brutes) est converti au format AVCC attendu
/// par Apple : chaque NAL précédée de sa longueur sur 4 octets.
final class H264LayerRenderer {
    private let renderer: AVSampleBufferVideoRenderer
    private var format: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    init(layer: AVSampleBufferDisplayLayer, sps: [UInt8]?, pps: [UInt8]?) {
        renderer = layer.sampleBufferRenderer
        renderer.flush()
        self.sps = sps
        self.pps = pps
        makeFormat()
    }

    /// Retourne false si l'image n'a pas pu être affichée (le flux doit repartir d'une image clé).
    func render(_ au: AccessUnit) -> Bool {
        var slices: [[UInt8]] = []
        var changed = false
        for nal in au.nalUnits {
            switch nalType(nal) {
            case NalType.sps: if nal != sps { sps = nal; changed = true }
            case NalType.pps: if nal != pps { pps = nal; changed = true }
            case NalType.aud: break
            default: slices.append(nal)
            }
        }
        if changed || format == nil { makeFormat() } // SPS/PPS dans le flux, ou changement de résolution
        guard let format, !slices.isEmpty else { return format != nil }

        if renderer.status == .failed { renderer.flush() ; return false }
        guard let sample = makeSample(slices, format: format) else { return false }
        renderer.enqueue(sample)
        return true
    }

    private func makeFormat() {
        guard let sps, let pps else { return }
        var fmt: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        if status == noErr { format = fmt }
    }

    private func makeSample(_ slices: [[UInt8]], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc: [UInt8] = []
        avcc.reserveCapacity(slices.reduce(0) { $0 + $1.count + 4 })
        for s in slices {
            let n = UInt32(s.count)
            avcc += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            avcc += s
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        // Pas d'horloge : on affiche dès que c'est décodé, on vise la latence.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
