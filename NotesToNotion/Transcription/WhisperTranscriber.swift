import Accelerate
import AVFoundation
import Foundation
import WhisperKit

/// Transcribes audio fully on-device via WhisperKit, so notes no longer
/// depend on Gemini's audio quota/rate limits for the (expensive, slow)
/// transcription step — only the text summary still goes to Gemini.
///
/// The pipeline is loaded once and reused: reinitializing WhisperKit per
/// recording would reload the ~626MB model every time. First use downloads
/// the model (one-time) and compiles it for Core ML, which can take a while;
/// subsequent uses are fast.
actor WhisperTranscriber {
    static let shared = WhisperTranscriber()

    /// Argmax's recommended variant for maximum multilingual accuracy
    /// (large-v3, compressed for Apple platforms).
    private static let modelName = "large-v3-v20240930_626MB"

    private var pipeline: WhisperKit?

    private struct LabeledSegment {
        let speaker: String
        let start: Float
        let text: String
    }

    func transcribe(audioURL: URL) async throws -> String {
        let pipeline = try await loadedPipeline()

        // Deterministic greedy decoding. WhisperKit's default
        // `temperatureFallbackCount` re-decodes any segment that fails its
        // quality gates with *random* (temperature > 0) sampling, so the
        // same recording produced a different — and sometimes empty —
        // transcript on every run. Disabling the compression-ratio and
        // log-prob gates keeps best-effort text instead of discarding a
        // whole segment when speech is quiet or repetitive.
        let options = DecodingOptions(
            temperature: 0.0,
            temperatureFallbackCount: 0,
            compressionRatioThreshold: nil,
            logProbThreshold: nil
        )

        let isMixed = audioURL.lastPathComponent.hasPrefix("mixed-")
        let channelCount = (try? AVAudioFile(forReading: audioURL))?.processingFormat.channelCount ?? 1

        if isMixed && channelCount == 2 {
            return try await transcribeDualChannel(audioURL: audioURL, pipeline: pipeline, options: options)
        } else {
            return try await transcribeSingleChannel(audioURL: audioURL, pipeline: pipeline, options: options)
        }
    }

    private func transcribeDualChannel(
        audioURL: URL,
        pipeline: WhisperKit,
        options: DecodingOptions
    ) async throws -> String {
        // Canal 0 = Izquierdo = Estudiante (Micrófono)
        // Canal 1 = Derecho = Sensei (Audio del sistema)
        let (studentSamples, senseiSamples) = try Self.loadStereoChannels(from: audioURL)

        let studentHasVoice = Self.hasVoiceEnergy(studentSamples)
        let senseiHasVoice = Self.hasVoiceEnergy(senseiSamples)

        guard studentHasVoice || senseiHasVoice else {
            return ""
        }

        var labeledSegments: [LabeledSegment] = []

        if senseiHasVoice {
            let normalizedSensei = Self.peakNormalized(senseiSamples)
            let senseiResults = try await pipeline.transcribe(audioArray: normalizedSensei, decodeOptions: options)
            var hasSenseiSegments = false
            for segment in senseiResults.flatMap(\.segments) {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidSegmentText(text) {
                    labeledSegments.append(LabeledSegment(speaker: "Sensei", start: segment.start, text: text))
                    hasSenseiSegments = true
                }
            }
            if !hasSenseiSegments {
                let fullText = senseiResults.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidSegmentText(fullText) {
                    labeledSegments.append(LabeledSegment(speaker: "Sensei", start: 0.0, text: fullText))
                }
            }
        }

        if studentHasVoice {
            let normalizedStudent = Self.peakNormalized(studentSamples)
            let studentResults = try await pipeline.transcribe(audioArray: normalizedStudent, decodeOptions: options)
            var hasStudentSegments = false
            for segment in studentResults.flatMap(\.segments) {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidSegmentText(text) {
                    labeledSegments.append(LabeledSegment(speaker: "Estudiante", start: segment.start, text: text))
                    hasStudentSegments = true
                }
            }
            if !hasStudentSegments {
                let fullText = studentResults.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidSegmentText(fullText) {
                    labeledSegments.append(LabeledSegment(speaker: "Estudiante", start: 0.0, text: fullText))
                }
            }
        }

        guard !labeledSegments.isEmpty else {
            return ""
        }

        labeledSegments.sort { $0.start < $1.start }

        var lines: [String] = []
        for segment in labeledSegments {
            let timestamp = Self.formatTimestamp(segment.start)
            lines.append("[\(timestamp) \(segment.speaker)]: \(segment.text)")
        }

        return lines.joined(separator: "\n")
    }

    private func transcribeSingleChannel(
        audioURL: URL,
        pipeline: WhisperKit,
        options: DecodingOptions
    ) async throws -> String {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        guard Self.hasVoiceEnergy(samples) else {
            return ""
        }

        let normalized = Self.peakNormalized(samples)
        let results = try await pipeline.transcribe(audioArray: normalized, decodeOptions: options)
        let segments = results.flatMap(\.segments)

        var lines: [String] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isValidSegmentText(text) {
                let timestamp = Self.formatTimestamp(segment.start)
                lines.append("[\(timestamp) Estudiante]: \(text)")
            }
        }

        if lines.isEmpty {
            let fullText = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !fullText.isEmpty {
                return "[00:00 Estudiante]: \(fullText)"
            }
            return ""
        }

        return lines.joined(separator: "\n")
    }

    private static func loadStereoChannels(from audioURL: URL) throws -> (student: [Float], sensei: [Float]) {
        let audioFile = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputFormat = audioFile.processingFormat
        let channelCount = Int(inputFormat.channelCount)

        guard channelCount >= 2 else {
            let mono = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
            return (student: mono, sensei: [])
        }

        let totalFrames = audioFile.length
        guard totalFrames > 0 else {
            return (student: [], sensei: [])
        }

        var studentSamples: [Float] = []
        var senseiSamples: [Float] = []

        if inputFormat.sampleRate == 16000 {
            let chunkSize: AVAudioFrameCount = 32768
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkSize) else {
                throw AppError.recordingFailed("No se pudo asignar el buffer de audio.")
            }
            while audioFile.framePosition < totalFrames {
                let framesToRead = min(chunkSize, AVAudioFrameCount(totalFrames - audioFile.framePosition))
                try audioFile.read(into: buffer, frameCount: framesToRead)
                if let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
                    let count = Int(buffer.frameLength)
                    studentSamples.append(contentsOf: UnsafeBufferPointer(start: ch0, count: count))
                    senseiSamples.append(contentsOf: UnsafeBufferPointer(start: ch1, count: count))
                }
            }
            return (student: studentSamples, sensei: senseiSamples)
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 2,
            interleaved: false
        ) else {
            throw AppError.recordingFailed("No se pudo configurar el formato estéreo de 16 kHz.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AppError.recordingFailed("No se pudo inicializar el conversor de audio.")
        }

        let inputChunkCapacity: AVAudioFrameCount = 32768
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputChunkCapacity) else {
            throw AppError.recordingFailed("No se pudo asignar el buffer de entrada.")
        }

        let outputChunkCapacity = AVAudioFrameCount(ceil(Double(inputChunkCapacity) * 16000.0 / inputFormat.sampleRate)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkCapacity) else {
            throw AppError.recordingFailed("No se pudo asignar el buffer de salida.")
        }

        while audioFile.framePosition < totalFrames {
            let framesToRead = min(inputChunkCapacity, AVAudioFrameCount(totalFrames - audioFile.framePosition))
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)

            var isProvided = false
            var conversionError: NSError?
            _ = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if !isProvided {
                    isProvided = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            if let conversionError {
                throw AppError.recordingFailed("Error al convertir el audio: \(conversionError.localizedDescription)")
            }

            if outputBuffer.frameLength > 0,
               let ch0 = outputBuffer.floatChannelData?[0],
               let ch1 = outputBuffer.floatChannelData?[1] {
                let count = Int(outputBuffer.frameLength)
                studentSamples.append(contentsOf: UnsafeBufferPointer(start: ch0, count: count))
                senseiSamples.append(contentsOf: UnsafeBufferPointer(start: ch1, count: count))
            }
        }

        return (student: studentSamples, sensei: senseiSamples)
    }

    private static func hasVoiceEnergy(_ samples: [Float], threshold: Float = 0.015) -> Bool {
        guard !samples.isEmpty else { return false }
        var peak: Float = 0.0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak > threshold
    }

    /// Scales the whole signal so its loudest sample sits near full scale,
    /// leaving audio that's already loud enough (or effectively silent)
    /// untouched so we neither clip nor amplify pure noise.
    private static func peakNormalized(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0.0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        let target: Float = 0.95
        guard peak > 0.01, peak < target else { return samples }
        let gain = target / peak
        var output = [Float](repeating: 0, count: samples.count)
        var gainVar = gain
        vDSP_vsmul(samples, 1, &gainVar, &output, 1, vDSP_Length(samples.count))
        return output
    }

    private static func formatTimestamp(_ seconds: Float) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    private static func isValidSegmentText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let stripped = trimmed.trimmingCharacters(
            in: CharacterSet.punctuationCharacters
                .union(.whitespacesAndNewlines)
                .union(CharacterSet(charactersIn: "♪♫-—_~…[]()"))
        )
        return !stripped.isEmpty
    }

    private func loadedPipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        // On the Neural Engine this compressed model can emit garbage for
        // marginal recordings; CPU+GPU is stable, so keep it off the ANE.
        let computeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU
        )
        let config = WhisperKitConfig(model: Self.modelName, computeOptions: computeOptions)
        let pipeline = try await WhisperKit(config)
        self.pipeline = pipeline
        return pipeline
    }
}
