import Accelerate
import AVFoundation
import CoreGraphics
import CoreMedia
import os
import ScreenCaptureKit

/// Captures the Mac's system audio output (e.g. the other side of a video
/// call) independently of the microphone, via ScreenCaptureKit.
///
/// This is best-effort: if Screen Recording permission is missing or denied,
/// callers should fall back to mic-only audio rather than block recording.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var recordedFormat: AVAudioFormat?
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.gabrieloide.NotesToNotion.systemAudioWrite")

    private var startHostTime: CMTime?
    private var nextExpectedSampleTime: CMTime?

    // Pause/Resume state
    private var isPaused: Bool = false
    private var totalPausedDuration: CMTime = .zero
    private var pauseStartHostTime: CMTime?

    // Thread-safe level metering
    private struct LevelState {
        var currentLevel: Float = 0.0
        var lastBufferDate: Date = .distantPast
        var isPaused: Bool = false
    }
    private let levelState = OSAllocatedUnfairLock(initialState: LevelState())

    var currentLevel: Float {
        levelState.withLock { state in
            if state.isPaused || Date().timeIntervalSince(state.lastBufferDate) > 0.3 {
                return 0.0
            }
            return state.currentLevel
        }
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func start() async throws {
        // Only request permission if not already granted to avoid repeated prompts
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                throw AppError.recordingFailed("Screen Recording permission denied for system audio.")
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AppError.recordingFailed("no display available for system audio capture.")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        // Audio only: keep the unused video side of the stream as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)

        let startTime = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.sync {
            self.startHostTime = startTime
            self.nextExpectedSampleTime = startTime
            self.isPaused = false
            self.totalPausedDuration = .zero
            self.pauseStartHostTime = nil
        }

        levelState.withLock { state in
            state.currentLevel = 0.0
            state.lastBufferDate = Date()
            state.isPaused = false
        }

        try await stream.startCapture()
        self.stream = stream
    }

    func pause() {
        let pauseTime = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.sync {
            guard !self.isPaused else { return }
            self.isPaused = true
            self.pauseStartHostTime = pauseTime
        }
        levelState.withLock { state in
            state.isPaused = true
            state.currentLevel = 0.0
        }
    }

    func resume() {
        let resumeTime = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.sync {
            guard self.isPaused else { return }
            if let pauseStart = self.pauseStartHostTime {
                let pausedDelta = CMTimeSubtract(resumeTime, pauseStart)
                self.totalPausedDuration = CMTimeAdd(self.totalPausedDuration, pausedDelta)
                if let expected = self.nextExpectedSampleTime {
                    self.nextExpectedSampleTime = CMTimeAdd(expected, pausedDelta)
                }
            }
            self.pauseStartHostTime = nil
            self.isPaused = false
        }
        levelState.withLock { state in
            state.isPaused = false
            state.lastBufferDate = Date()
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil

        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.sync {
            if self.isPaused, let pauseStart = self.pauseStartHostTime {
                let pausedDelta = CMTimeSubtract(stopTime, pauseStart)
                if let expected = self.nextExpectedSampleTime {
                    self.nextExpectedSampleTime = CMTimeAdd(expected, pausedDelta)
                }
                self.isPaused = false
                self.pauseStartHostTime = nil
            }
            if let audioFile = self.audioFile, let format = self.recordedFormat, let expected = self.nextExpectedSampleTime {
                let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(stopTime, expected))
                if gapSeconds > 0.02 && gapSeconds < 3600 {
                    self.writeSilence(duration: gapSeconds, format: format, to: audioFile)
                }
            }
            self.audioFile = nil
        }

        levelState.withLock { state in
            state.currentLevel = 0.0
            state.isPaused = false
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        // Ignore incoming buffers while paused
        guard !isPaused else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(sampleBuffer: sampleBuffer) else { return }

        // Calculate live audio level
        let level = calculateLevel(from: pcmBuffer)
        levelState.withLock { state in
            state.currentLevel = level
            state.lastBufferDate = Date()
        }

        if audioFile == nil {
            do {
                audioFile = try AVAudioFile(
                    forWriting: fileURL,
                    settings: pcmBuffer.format.settings,
                    commonFormat: pcmBuffer.format.commonFormat,
                    interleaved: pcmBuffer.format.isInterleaved
                )
                recordedFormat = pcmBuffer.format
            } catch {
                print("WARN: Failed to create audioFile in SystemAudioRecorder: \(error)")
                return
            }
        }

        guard let audioFile, let format = recordedFormat else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid {
            let expectedTime = nextExpectedSampleTime ?? startHostTime ?? pts
            let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, expectedTime))
            if gapSeconds > 0.02 && gapSeconds < 3600 {
                writeSilence(duration: gapSeconds, format: format, to: audioFile)
            }

            let bufferDuration: CMTime
            let scDuration = CMSampleBufferGetDuration(sampleBuffer)
            if scDuration.isValid && CMTimeGetSeconds(scDuration) > 0 {
                bufferDuration = scDuration
            } else {
                let durationSeconds = Double(pcmBuffer.frameLength) / format.sampleRate
                bufferDuration = CMTime(seconds: durationSeconds, preferredTimescale: pts.timescale)
            }
            let nextTime = CMTimeAdd(pts, bufferDuration)
            if let current = nextExpectedSampleTime {
                nextExpectedSampleTime = CMTimeCompare(nextTime, current) > 0 ? nextTime : current
            } else {
                nextExpectedSampleTime = nextTime
            }
        }

        try? audioFile.write(from: pcmBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Best-effort capture: a mid-recording failure here just means the
        // merged note falls back to mic-only audio at mixing time.
    }

    private func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        var maxSample: Float = 0.0
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }

        if let floatChannelData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            for ch in 0..<channelCount {
                let ptr = floatChannelData[ch]
                var channelPeak: Float = 0.0
                vDSP_maxmgv(ptr, 1, &channelPeak, vDSP_Length(frameLength))
                if channelPeak > maxSample {
                    maxSample = channelPeak
                }
            }
        } else if let int16ChannelData = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            for ch in 0..<channelCount {
                let ptr = int16ChannelData[ch]
                for i in 0..<frameLength {
                    let absVal = Float(abs(Int32(ptr[i]))) / 32768.0
                    if absVal > maxSample {
                        maxSample = absVal
                    }
                }
            }
        }

        guard maxSample > 0.0001 else { return 0.0 }
        let db = 20.0 * log10(maxSample)
        let minDb: Float = -50.0
        let normalized = max(0.0, min(1.0, (db - minDb) / (0.0 - minDb)))
        return normalized
    }

    private func writeSilence(duration: Double, format: AVAudioFormat, to file: AVAudioFile) {
        let totalFrames = AVAudioFrameCount(duration * format.sampleRate)
        guard totalFrames > 0 else { return }
        let chunkSize: AVAudioFrameCount = 8192
        guard let silenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else { return }

        var remaining = totalFrames
        while remaining > 0 {
            let currentFrames = min(remaining, chunkSize)
            silenceBuffer.frameLength = currentFrames
            let audioBufferList = silenceBuffer.mutableAudioBufferList
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            do {
                try file.write(from: silenceBuffer)
            } catch {
                print("WARN: Failed to write silence buffer: \(error)")
                break
            }
            remaining -= currentFrames
        }
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
