import AVFoundation

/// Offline-mixes the microphone and system-audio recordings into a single
/// m4a file, so Gemini receives one chronologically coherent track instead
/// of two independent ones.
enum AudioMixer {
    private static let renderSampleRate = 44100.0
    // Quiet recordings (soft-spoken mic input) can fall below Whisper's
    // no-speech-confidence threshold even though a human hears them fine.
    // Boost with headroom, clamped to avoid clipping any louder passages.
    private static let gain: Float = 3.0

    static func mix(micURL: URL, systemURL: URL, outputURL: URL) throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let systemFile = try AVAudioFile(forReading: systemURL)
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: renderSampleRate, channels: 2) else {
            throw AppError.recordingFailed("couldn't create a render format for mixing.")
        }

        let engine = AVAudioEngine()
        let micPlayer = AVAudioPlayerNode()
        let systemPlayer = AVAudioPlayerNode()
        engine.attach(micPlayer)
        engine.attach(systemPlayer)
        engine.connect(micPlayer, to: engine.mainMixerNode, format: micFile.processingFormat)
        engine.connect(systemPlayer, to: engine.mainMixerNode, format: systemFile.processingFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: renderFormat)

        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()

        micPlayer.scheduleFile(micFile, at: nil)
        systemPlayer.scheduleFile(systemFile, at: nil)
        micPlayer.play()
        systemPlayer.play()

        let micDuration = Double(micFile.length) / micFile.processingFormat.sampleRate
        let systemDuration = Double(systemFile.length) / systemFile.processingFormat.sampleRate
        // Half a second of headroom so the shorter track's tail isn't cut off.
        let totalFrames = AVAudioFrameCount((max(micDuration, systemDuration) + 0.5) * renderFormat.sampleRate)

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: renderFormat.sampleRate,
                AVNumberOfChannelsKey: renderFormat.channelCount,
            ]
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            throw AppError.recordingFailed("couldn't allocate a render buffer for mixing.")
        }

        var framesRendered: AVAudioFrameCount = 0
        while framesRendered < totalFrames {
            let framesToRender = min(buffer.frameCapacity, totalFrames - framesRendered)
            let status = try engine.renderOffline(framesToRender, to: buffer)
            switch status {
            case .success:
                applyGain(gain, to: buffer)
                try outputFile.write(from: buffer)
                framesRendered += framesToRender
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw AppError.recordingFailed("offline audio mixing failed.")
            @unknown default:
                throw AppError.recordingFailed("offline audio mixing failed.")
            }
        }

        engine.stop()
    }

    private static func applyGain(_ gain: Float, to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for i in 0..<frameLength {
                samples[i] = max(-1.0, min(1.0, samples[i] * gain))
            }
        }
    }
}
