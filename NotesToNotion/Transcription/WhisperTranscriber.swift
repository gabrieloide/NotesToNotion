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

    func transcribe(audioURL: URL) async throws -> String {
        let pipeline = try await loadedPipeline()

        // Load as 16 kHz float samples and level-normalize before decoding.
        // The mic-only fallback records ~10 dB quieter than the mixed track
        // (it applies no makeup gain), and WhisperKit treats very quiet
        // input as marginal — which pushes the decoder into the failure
        // modes below. Normalizing here fixes both recording paths at once.
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        let normalized = Self.peakNormalized(samples)

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

        let results = try await pipeline.transcribe(audioArray: normalized, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }

    /// Scales the whole signal so its loudest sample sits near full scale,
    /// leaving audio that's already loud enough (or effectively silent)
    /// untouched so we neither clip nor amplify pure noise.
    private static func peakNormalized(_ samples: [Float]) -> [Float] {
        let peak = samples.map(abs).max() ?? 0
        let target: Float = 0.95
        guard peak > 0.01, peak < target else { return samples }
        let gain = target / peak
        return samples.map { $0 * gain }
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
