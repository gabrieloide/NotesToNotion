import AVFoundation
import Darwin

/// Offline-mixes the microphone and system-audio recordings into a single
/// m4a file, so Gemini receives one chronologically coherent track instead
/// of two independent ones.
enum AudioMixer {
    private static let renderSampleRate = 44100.0
    private static let postMixGain: Float = 1.2

    static func mix(micURL: URL, systemURL: URL, outputURL: URL) throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let systemFile = try AVAudioFile(forReading: systemURL)

        guard systemFile.length > 0 else {
            throw AppError.recordingFailed("system audio file contains no samples.")
        }
        guard micFile.length > 0 else {
            throw AppError.recordingFailed("microphone audio file contains no samples.")
        }

        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: renderSampleRate, channels: 2) else {
            throw AppError.recordingFailed("couldn't create a render format for mixing.")
        }
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: renderSampleRate, channels: 1) else {
            throw AppError.recordingFailed("couldn't create a mono format for mixing.")
        }

        let engine = AVAudioEngine()
        let micPlayer = AVAudioPlayerNode()
        let systemPlayer = AVAudioPlayerNode()
        let sysMonoMixer = AVAudioMixerNode()

        engine.attach(micPlayer)
        engine.attach(systemPlayer)
        engine.attach(sysMonoMixer)

        // Mic audio is mono and connects directly to mainMixerNode panned 100% left (-1.0) -> Channel 0 (Estudiante)
        engine.connect(micPlayer, to: engine.mainMixerNode, format: micFile.processingFormat)
        // System audio connects to sysMonoMixer (which downmixes to mono if 2-ch),
        // and connects to mainMixerNode with monoFormat panned 100% right (+1.0) -> Channel 1 (Sensei)
        engine.connect(systemPlayer, to: sysMonoMixer, format: systemFile.processingFormat)
        engine.connect(sysMonoMixer, to: engine.mainMixerNode, format: monoFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: renderFormat)

        micPlayer.pan = -1.0
        sysMonoMixer.pan = 1.0
        micPlayer.volume = 1.0
        systemPlayer.volume = 1.0
        sysMonoMixer.volume = 1.0

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
                AVEncoderBitRateKey: 96000,
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
                applyGainAndSoftClip(gain, to: buffer)
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

    private static func applyGainAndSoftClip(_ gain: Float, to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for i in 0..<frameLength {
                let scaled = samples[i] * gain
                samples[i] = max(-1.0, min(1.0, tanhf(scaled)))
            }
        }
    }
}
