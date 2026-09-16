import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures the Mac's system audio output (e.g. the other side of a video
/// call) independently of the microphone, via ScreenCaptureKit.
///
/// This is best-effort: the most common failure is a denied Screen
/// Recording permission, and callers should fall back to mic-only audio
/// rather than let that block a recording.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.gabrieloide.NotesToNotion.systemAudioWrite")

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AppError.recordingFailed("no display available for system audio capture.")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Audio only: keep the unused video side of the stream as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        writeQueue.sync { audioFile = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcmBuffer = AVAudioPCMBuffer(sampleBuffer: sampleBuffer) else { return }

        if audioFile == nil {
            audioFile = try? AVAudioFile(
                forWriting: fileURL,
                settings: pcmBuffer.format.settings,
                commonFormat: pcmBuffer.format.commonFormat,
                interleaved: pcmBuffer.format.isInterleaved
            )
        }
        try? audioFile?.write(from: pcmBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Best-effort capture: a mid-recording failure here just means the
        // merged note falls back to mic-only audio at mixing time.
    }
}

private extension AVAudioPCMBuffer {
    /// ScreenCaptureKit delivers audio as `CMSampleBuffer`s, but the rest of
    /// AVFoundation (and our mixer) works with `AVAudioPCMBuffer`. There's no
    /// direct initializer for that on macOS, so the raw PCM bytes are copied
    /// out via the lower-level Core Media buffer-list APIs.
    convenience init?(sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        self.init(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples))
        self.frameLength = self.frameCapacity

        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, sizeNeeded > 0 else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let sourceListPointer = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceListPointer,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceListPointer)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(self.mutableAudioBufferList)
        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            let source = sourceBuffers[index]
            guard let sourceData = source.mData else { continue }
            destinationBuffers[index].mData?.copyMemory(from: sourceData, byteCount: Int(source.mDataByteSize))
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
        }
    }
}
