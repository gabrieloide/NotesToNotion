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
        // Channel 0 = Left = Estudiante (Mic)
        // Channel 1 = Right = Sensei (System Audio)
        let studentSamples = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: audioURL.path,
            channelMode: .specificChannel(0)
        )
        let senseiSamples = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: audioURL.path,
            channelMode: .specificChannel(1)
        )

        let studentHasVoice = Self.hasVoiceEnergy(studentSamples)
        let senseiHasVoice = Self.hasVoiceEnergy(senseiSamples)

        guard studentHasVoice || senseiHasVoice else {
            return ""
        }

        var labeledSegments: [LabeledSegment] = []

        if senseiHasVoice {
            let normalizedSensei = Self.peakNormalized(senseiSamples)
            let senseiResults = try await pipeline.transcribe(audioArray: normalizedSensei, decodeOptions: options)
            for segment in senseiResults.flatMap(\.segments) {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidSegmentText(text) {
                    labeledSegments.append(LabeledSegment(speaker: "Sensei", start: segment.start, text: text))
                }
            }
        }

        if studentHasVoice {
            let normalizedStudent = Self.peakNormalized(studentSamples)
            let studentResults = try await pipeline.transcribe(audioArray: normalizedStudent, decodeOptions: options)
            for segment in studentResults.flatMap(\.segments) {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidSegmentText(text) {
                    labeledSegments.append(LabeledSegment(speaker: "Estudiante", start: segment.start, text: text))
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
                lines.append("[\(timestamp)]: \(text)")
            }
        }

        if lines.isEmpty {
            let fullText = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !fullText.isEmpty {
                return "[00:00]: \(fullText)"
            }
            return ""
        }

        return lines.joined(separator: "\n")
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
