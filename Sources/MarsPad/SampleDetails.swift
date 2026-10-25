import Foundation
import AudioToolbox

struct SampleDetails {
    let duration: Double?
    let bitRate: UInt32?
    let bitDepth: UInt32?
    let sampleRate: Double
    let channels: UInt32
    let compressed: Bool

    var summary: String {
        let durationText = duration.map { String(format: "%@%.3f s", compressed ? "≈" : "", $0) } ?? "Unavailable"
        let rateText = bitRate.map { String(format: "%.1f kb/s", Double($0) / 1000) } ?? "Unavailable"
        let depthText = bitDepth.map { " · \($0)-bit" } ?? ""
        return "Duration: \(durationText) · Bit rate: \(rateText)\(depthText) · \(String(format: "%.1f", sampleRate / 1000)) kHz · \(channels) ch"
    }

    // Read file headers and packet information only; never decode the audio.
    // Called off the interface thread, independently of preview playback.
    static func read(_ url: URL) throws -> SampleDetails {
        var handle: AudioFileID?
        let opened = AudioFileOpenURL(url as CFURL, .readPermission, 0, &handle)
        guard opened == noErr, let file = handle else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(opened))
        }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let result = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format)
        guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        var seconds = Double(0)
        size = UInt32(MemoryLayout<Double>.size)
        let hasDuration = AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &seconds) == noErr
        var rate = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &rate)
        let pcm = format.mFormatID == kAudioFormatLinearPCM
        if pcm {
            // PCM payload rate excludes container headers and metadata chunks.
            let calculated = format.mSampleRate * Double(format.mBitsPerChannel) * Double(format.mChannelsPerFrame)
            if calculated > 0 && calculated <= Double(UInt32.max) { rate = UInt32(calculated) }
        }
        return SampleDetails(duration: hasDuration && seconds.isFinite && seconds >= 0 ? seconds : nil,
                             bitRate: rate > 0 ? rate : nil,
                             bitDepth: pcm && format.mBitsPerChannel > 0 ? format.mBitsPerChannel : nil,
                             sampleRate: format.mSampleRate, channels: format.mChannelsPerFrame, compressed: !pcm)
    }
}

enum BuildInfo {
    static var footer: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let commit = Bundle.main.object(forInfoDictionaryKey: "BuildGitCommit") as? String ?? "unpackaged"
        return "v\(version) · \(commit)"
    }
}
