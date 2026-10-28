import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import os
import ScreenCaptureKit

/// Captures the Mac's system audio output (e.g. the other side of a video
/// call) independently of the microphone, using a Dual-Engine architecture:
/// 1. Primary engine: CoreAudio Process Tap (CATapDescription), capturing system audio
///    directly at the HAL level without requiring kTCCServiceScreenCapture.
/// 2. Secondary fallback engine: ScreenCaptureKit (SCStream).
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private enum Engine {
        case coreAudioTap(tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID)
        case screenCaptureKit(stream: SCStream)
    }

    private var activeEngine: Engine?
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var recordedFormat: AVAudioFormat?
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.gabrieloide.NotesToNotion.systemAudioWrite")

    private var startHostTime: CMTime?
    private var nextExpectedSampleTime: CMTime?

    // Pause/Resume state
    private var isPaused: Bool = false
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
        // 1. Intentar primero con CoreAudio Process Tap (CATapDescription) en el HAL (macOS 14.2+)
        if #available(macOS 14.2, *) {
            do {
                try startCoreAudioProcessTap()
                print("SystemAudioRecorder: started via CoreAudio Process Tap (HAL)")
                return
            } catch {
                print("WARN: CoreAudio Process Tap unavailable (\(error)), falling back to ScreenCaptureKit...")
            }
        }

        // 2. Fallback a ScreenCaptureKit
        try await startScreenCaptureKit()
        print("SystemAudioRecorder: started via ScreenCaptureKit fallback")
    }

    // MARK: - CoreAudio Process Tap (Primary Engine)

    @available(macOS 14.2, *)
    private func startCoreAudioProcessTap() throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        var tapID: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            throw AppError.recordingFailed("AudioHardwareCreateProcessTap failed with code \(status)")
        }

        // Leer el dispositivo de salida por defecto del sistema
        var defaultOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultOutputDeviceID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AppError.recordingFailed("Failed to get default output device: \(status)")
        }

        // Leer UID del dispositivo de salida
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        withUnsafeMutablePointer(to: &uidCF) { ptr in
            status = AudioObjectGetPropertyData(defaultOutputDeviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let outputUID = uidCF as String? else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AppError.recordingFailed("Failed to read output device UID")
        }

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotesToNotionTapAggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var aggregateDeviceID: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AppError.recordingFailed("AudioHardwareCreateAggregateDevice failed: \(status)")
        }

        // Obtener formato de audio del aggregate device
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(aggregateDeviceID, &formatAddress, 0, nil, &asbdSize, &asbd)
        guard status == noErr, let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw AppError.recordingFailed("Failed to get aggregate stream format")
        }

        var fileSettings = avFormat.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: fileSettings,
            commonFormat: avFormat.commonFormat,
            interleaved: avFormat.isInterleaved
        )

        let startTime = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.sync {
            self.audioFile = file
            self.recordedFormat = avFormat
            self.startHostTime = startTime
            self.nextExpectedSampleTime = startTime
            self.isPaused = false
            self.pauseStartHostTime = nil
        }

        levelState.withLock { state in
            state.currentLevel = 0.0
            state.lastBufferDate = Date()
            state.isPaused = false
        }

        let rawSelf = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(aggregateDeviceID, { (deviceID, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData) -> OSStatus in
            guard let inClientData else { return noErr }
            let recorder = Unmanaged<SystemAudioRecorder>.fromOpaque(inClientData).takeUnretainedValue()
            recorder.handleTapAudio(inInputData: inInputData)
            return noErr
        }, rawSelf, &procID)

        guard status == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw AppError.recordingFailed("AudioDeviceCreateIOProcID failed: \(status)")
        }

        status = AudioDeviceStart(aggregateDeviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw AppError.recordingFailed("AudioDeviceStart failed: \(status)")
        }

        self.activeEngine = .coreAudioTap(tapID: tapID, aggregateID: aggregateDeviceID, procID: procID)
    }

    private func handleTapAudio(inInputData: UnsafePointer<AudioBufferList>) {
        guard !isPaused else { return }
        guard let format = recordedFormat else { return }

        let ablPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let firstBuffer = ablPointer.first, firstBuffer.mDataByteSize > 0 else { return }

        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let frameCount = AVAudioFrameCount(firstBuffer.mDataByteSize / bytesPerFrame)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let dstPointer = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for i in 0..<min(ablPointer.count, dstPointer.count) {
            let src = ablPointer[i]
            if let srcData = src.mData, let dstData = dstPointer[i].mData {
                dstData.copyMemory(from: srcData, byteCount: Int(src.mDataByteSize))
                dstPointer[i].mDataByteSize = src.mDataByteSize
            }
        }

        let level = calculateLevel(from: pcmBuffer)
        levelState.withLock { state in
            state.currentLevel = level
            state.lastBufferDate = Date()
        }

        writeQueue.async {
            guard !self.isPaused, let file = self.audioFile else { return }
            do {
                try file.write(from: pcmBuffer)
            } catch {
                print("ERROR writing system audio tap: \(error)")
            }
        }
    }

    // MARK: - ScreenCaptureKit (Fallback Engine)

    private func startScreenCaptureKit() async throws {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
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
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)

        try await stream.startCapture()
        self.stream = stream
        self.activeEngine = .screenCaptureKit(stream: stream)

        let startTime = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.sync {
            self.startHostTime = startTime
            self.nextExpectedSampleTime = startTime
            self.isPaused = false
            self.pauseStartHostTime = nil
        }

        levelState.withLock { state in
            state.currentLevel = 0.0
            state.lastBufferDate = Date()
            state.isPaused = false
        }
    }

    // MARK: - Control and Lifecycle

    func synchronizeStartTime() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.sync {
            guard self.audioFile == nil else { return }
            self.startHostTime = now
            self.nextExpectedSampleTime = now
        }
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
        switch activeEngine {
        case .coreAudioTap(let tapID, let aggID, let procID):
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
            AudioHardwareDestroyAggregateDevice(aggID)
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
        case .screenCaptureKit(let stream):
            try? await stream.stopCapture()
        case nil:
            if let stream {
                try? await stream.stopCapture()
            }
        }
        self.activeEngine = nil
        self.stream = nil

        let endHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.sync {
            if self.isPaused, let pauseStart = self.pauseStartHostTime {
                let pausedDelta = CMTimeSubtract(endHostTime, pauseStart)
                if CMTimeCompare(pausedDelta, .zero) > 0 {
                    if let expected = self.nextExpectedSampleTime {
                        self.nextExpectedSampleTime = CMTimeAdd(expected, pausedDelta)
                    }
                }
                self.pauseStartHostTime = nil
                self.isPaused = false
            }
            if let audioFile = self.audioFile, let format = self.recordedFormat, let expected = self.nextExpectedSampleTime {
                let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(endHostTime, expected))
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

    // MARK: - ScreenCaptureKit Stream Delegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard !isPaused else { return }
        guard let pcmBuffer = AVAudioPCMBuffer(sampleBuffer: sampleBuffer) else { return }

        let level = calculateLevel(from: pcmBuffer)
        levelState.withLock { state in
            state.currentLevel = level
            state.lastBufferDate = Date()
        }

        if audioFile == nil {
            do {
                var fileSettings = pcmBuffer.format.settings
                fileSettings[AVLinearPCMIsNonInterleaved] = false
                audioFile = try AVAudioFile(
                    forWriting: fileURL,
                    settings: fileSettings,
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

        do {
            try audioFile.write(from: pcmBuffer)
        } catch {
            print("ERROR writing system audio: \(error)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Best-effort capture: a mid-recording failure here just means the
        // merged note falls back to mic-only audio at mixing time.
    }

    // MARK: - Level Metering and Silence Fill

    private func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        var maxSample: Float = 0.0
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }

        if let floatChannelData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let isInterleaved = buffer.format.isInterleaved
            if isInterleaved {
                let ptr = floatChannelData[0]
                for ch in 0..<channelCount {
                    var channelPeak: Float = 0.0
                    vDSP_maxmgv(ptr.advanced(by: ch), channelCount, &channelPeak, vDSP_Length(frameLength))
                    if channelPeak > maxSample {
                        maxSample = channelPeak
                    }
                }
            } else {
                for ch in 0..<channelCount {
                    let ptr = floatChannelData[ch]
                    var channelPeak: Float = 0.0
                    vDSP_maxmgv(ptr, 1, &channelPeak, vDSP_Length(frameLength))
                    if channelPeak > maxSample {
                        maxSample = channelPeak
                    }
                }
            }
        } else if let int16ChannelData = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let isInterleaved = buffer.format.isInterleaved
            if isInterleaved {
                let ptr = int16ChannelData[0]
                let totalSamples = frameLength * channelCount
                for i in 0..<totalSamples {
                    let absVal = Float(abs(Int32(ptr[i]))) / 32768.0
                    if absVal > maxSample {
                        maxSample = absVal
                    }
                }
            } else {
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
