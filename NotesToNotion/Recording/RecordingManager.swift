import AVFoundation
import Foundation

final class RecordingManager {
    private var micRecorder: AVAudioRecorder?
    private var systemAudioRecorder: SystemAudioRecorder?
    private var systemAudioURL: URL?
    private(set) var isCapturingSystemAudio: Bool = false
    private(set) var isPaused: Bool = false

    func start() async throws {
        try await ensureMicrophonePermission()

        let timestamp = Int(Date().timeIntervalSince1970)
        let micURL = AudioStore.newRecordingURL(name: "mic-\(timestamp).m4a")

        // Mono at a low bitrate: enough for voice and keeps the file small
        // even for long recordings.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
        ]

        let recorder = try AVAudioRecorder(url: micURL, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        // Start system audio capture before or simultaneously with the microphone
        // so startHostTime aligns with the microphone start.
        let systemURL = AudioStore.newRecordingURL(name: "system-\(timestamp).caf")
        let systemRecorder = SystemAudioRecorder(fileURL: systemURL)
        do {
            try await systemRecorder.start()
            self.systemAudioRecorder = systemRecorder
            self.systemAudioURL = systemURL
            self.isCapturingSystemAudio = true
        } catch {
            print("WARN: System audio capture unavailable: \(error)")
            self.systemAudioRecorder = nil
            self.systemAudioURL = nil
            self.isCapturingSystemAudio = false
        }

        guard recorder.record() else {
            AudioStore.hasActiveRecording = false
            if let systemAudioRecorder {
                await systemAudioRecorder.stop()
                self.systemAudioRecorder = nil
                self.systemAudioURL = nil
                self.isCapturingSystemAudio = false
            }
            throw AppError.recordingFailed("the microphone didn't start recording.")
        }
        AudioStore.hasActiveRecording = true
        self.systemAudioRecorder?.synchronizeStartTime()
        self.micRecorder = recorder
        self.isPaused = false
    }

    func pause() {
        guard !isPaused else { return }
        micRecorder?.pause()
        systemAudioRecorder?.pause()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        micRecorder?.record()
        systemAudioRecorder?.resume()
        isPaused = false
    }

    func currentLevels() -> (mic: Float, system: Float) {
        guard !isPaused, let micRecorder, micRecorder.isRecording else {
            return (mic: 0.0, system: 0.0)
        }
        micRecorder.updateMeters()
        let averagePower = micRecorder.averagePower(forChannel: 0)
        let minDb: Float = -50.0
        let micLevel = max(0.0, min(1.0, (averagePower - minDb) / (0.0 - minDb)))

        let systemLevel: Float
        if isCapturingSystemAudio, let sysRecorder = systemAudioRecorder {
            systemLevel = sysRecorder.currentLevel
        } else {
            systemLevel = 0.0
        }

        return (mic: micLevel, system: systemLevel)
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    func stop() async -> URL? {
        defer { AudioStore.hasActiveRecording = false }
        isPaused = false
        isCapturingSystemAudio = false
        guard let micRecorder else { return nil }
        let micURL = micRecorder.url
        micRecorder.stop()
        self.micRecorder = nil
        guard FileManager.default.fileExists(atPath: micURL.path) else {
            print("DEBUG stop(): mic file does not exist at \(micURL.path)")
            return nil
        }
        print("DEBUG stop(): mic file size = \(fileSize(micURL)) bytes at \(micURL.path)")

        guard let systemAudioRecorder, let systemAudioURL else {
            print("DEBUG stop(): no system audio recorder, returning mic-only")
            return micURL
        }
        await systemAudioRecorder.stop()
        self.systemAudioRecorder = nil
        self.systemAudioURL = nil

        guard FileManager.default.fileExists(atPath: systemAudioURL.path) else {
            print("DEBUG stop(): system audio file does not exist, returning mic-only")
            return micURL
        }
        print("DEBUG stop(): system file size = \(fileSize(systemAudioURL)) bytes at \(systemAudioURL.path)")

        let mixedURL = AudioStore.newRecordingURL(name: "mixed-\(Int(Date().timeIntervalSince1970)).m4a")
        do {
            try AudioMixer.mix(micURL: micURL, systemURL: systemAudioURL, outputURL: mixedURL)
            print("DEBUG stop(): mixed file size = \(fileSize(mixedURL)) bytes at \(mixedURL.path)")
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemAudioURL)
            return mixedURL
        } catch {
            // Mixing failed (e.g. an empty/corrupt system track) — keep the
            // mic-only recording instead of losing the note entirely.
            print("DEBUG stop(): mixing threw \(error), falling back to mic-only")
            try? FileManager.default.removeItem(at: systemAudioURL)
            return micURL
        }
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw AppError.microphonePermissionDenied }
        default:
            throw AppError.microphonePermissionDenied
        }
    }
}
